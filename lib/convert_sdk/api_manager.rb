# frozen_string_literal: true

require "json"

module ConvertSdk
  # The outbound delivery manager — it owns the {VisitorsQueue}, the tracking
  # endpoint, queue release, and THE wire-payload builder.
  #
  # == Wire-translation boundary #2 (the only outbound converter)
  #
  # {Config#to_internal} is the single INBOUND snake_case=>camelCase site; this
  # class's payload builder is the single OUTBOUND one. Everything in between —
  # +StoreData+, the queued events — is ALREADY wire-shaped, string-keyed data.
  # The payload is therefore built EXCLUSIVELY here as string-keyed camelCase
  # hashes and serialized with +JSON.generate+ — never string-concatenated JSON,
  # never symbol keys anywhere in the wire hashes. The result is byte-identical to
  # the JS wire contract (+api-manager.ts:197-234+).
  #
  # == The payload shape
  #
  #   {
  #     "accountId" => …, "projectId" => …,
  #     "enrichData" => false, "source" => "ruby-sdk",
  #     "visitors" => [
  #       { "visitorId" => …, "segments" => {…}?, "events" => [ {…}, … ] }
  #     ]
  #   }
  #
  # POSTed to +{track_endpoint with [project_id] replaced}/track/{sdkKey}+ via the
  # single {HttpClient} port (the ConvertAgent User-Agent invariant rides
  # automatically; an +Authorization: Bearer {secret}+ header is passed through the
  # port's +headers+ param when a secret is configured — the port enforces the
  # HTTPS-only guard). An empty queue is a no-op.
  #
  # == enrichData / source (verified against JS source)
  #
  # +enrichData+ is +false+: the JS formula is +!objectDeepValue(config,'dataStore')+
  # (+api-manager.ts:94+), which is +false+ whenever a dataStore is configured; the
  # Ruby SDK always provides at least a MemoryStore, and the research register is
  # silent on treating a MemoryStore-only config as "no store", so JS parity holds.
  # +source+ is +"ruby-sdk"+ — the Ruby analogue of JS +config?.network?.source ||
  # 'js-sdk'+ (+api-manager.ts:115+).
  #
  # == Lock discipline (NFR2/NFR13)
  #
  # {#release_queue} drains the queue with an atomic drain-and-swap INSIDE the
  # queue lock, then builds the payload and performs the HTTP POST OUTSIDE the
  # lock. The enqueue path never blocks the caller on network I/O. A failed POST
  # does NOT raise (the full queue-retention behaviour lands in Story 4.2); it is
  # logged and swallowed so the Client boundary never crashes the host.
  #
  # @api private
  class ApiManager
    # The SDK identifier sent as the tracking payload +source+ (JS analogue of
    # +config?.network?.source || 'js-sdk'+ — api-manager.ts:115).
    SOURCE = "ruby-sdk"

    # JS parity: +!objectDeepValue(config,'dataStore')+ is false whenever a
    # dataStore is configured, and Ruby always provides one (api-manager.ts:94).
    ENRICH_DATA = false

    # @param config [Config] the validated configuration (track endpoint, sdk_key,
    #   sdk_key_secret).
    # @param data_manager [DataManager] supplies +account_id+ / +project_id+ for
    #   the payload and the +[project_id]+ URL substitution.
    # @param http_client [HttpClient] the single hardened HTTP port.
    # @param event_manager [EventManager] fires {SystemEvents::API_QUEUE_RELEASED}
    #   after a release (JS parity).
    # @param log_manager [LogManager] the redacting logging surface.
    def initialize(config:, data_manager:, http_client:, event_manager:, log_manager:)
      @config = config
      @data_manager = data_manager
      @http_client = http_client
      @event_manager = event_manager
      @log_manager = log_manager
      @queue = VisitorsQueue.new(log_manager: log_manager)
      # The SECOND and FINAL BackgroundTimer instance (architecture Decision 6 —
      # one class, two instances: the refresh timer is 2.7's, this is the flush
      # timer, owned here). It is built and registered with ForkGuard NOW but
      # NEVER started in the factory (NFR4 — no threads until first use); it is
      # lazily started on the first enqueue. A +nil+ flush_interval is the
      # timer-off mode (BackgroundTimer#start is then a guarded no-op — the
      # Lambda recipe for 4.6: explicit flush + size trigger still deliver).
      @flush_timer = BackgroundTimer.new(
        interval: @config.flush_interval,
        log_manager: log_manager,
        name: "flush"
      ) { flush_tick }
      ForkGuard.register_timer(@flush_timer)
      # Story 4.4 — child queue-ownership clear. ForkGuard fires this callback in
      # a forked child (after marking timers dead). The child inherits a COPY of
      # the parent's queued events; clearing it here is what makes the child
      # start EMPTY so it never double-delivers the parent's events (the parent's
      # timer still runs there and delivers them). ForkGuard stays generic — it
      # knows nothing about the queue; ApiManager owns its own clear (architecture
      # Decision 6 callback-registry design).
      ForkGuard.register_child_callback(-> { clear_queue_ownership })
    end

    # @return [VisitorsQueue] the underlying per-visitor event queue.
    attr_reader :queue

    # Enqueue one wire-shaped event for a visitor (delegates to the queue's
    # per-visitor merge), then drive the two automatic delivery triggers:
    #
    # 1. LAZY-START the flush timer (NFR4 — the first enqueue in each process is
    #    "first use"; idempotent + re-arms after a fork via 2.6's BackgroundTimer).
    # 2. SIZE trigger — when the queue reaches +event_batch_size+, release with
    #    reason +"size"+ DIRECTLY on this thread (JS api-manager.ts:197-198). The
    #    enqueue itself is pure in-memory and the size-trigger release POSTs
    #    OUTSIDE the queue lock, so the caller is never blocked on the network
    #    (NFR2) — only the brief queue-lock acquisition.
    #
    # @param visitor_id [String] the visitor the event belongs to.
    # @param event [Hash{String=>Object}] a wire-shaped event hash.
    # @param segments [Hash{String=>Object}, nil] report-segments, attached only
    #   when this enqueue first creates the visitor's queue entry.
    # @return [void]
    def enqueue(visitor_id, event, segments: nil)
      @queue.enqueue(visitor_id, event, segments: segments)
      ensure_flush_timer!
      release_queue("size") if @queue.size >= @config.event_batch_size
    end

    # Release the queue — the SINGLE delivery implementation all three triggers
    # (explicit +flush+, size, interval) converge on. Drain-and-swap INSIDE the
    # queue lock, then build the wire payload and POST it OUTSIDE the lock (the
    # enqueue path is never blocked on network I/O — NFR2). An empty queue is a
    # no-op.
    #
    # On SUCCESS: an +info+ line and the {SystemEvents::API_QUEUE_RELEASED}
    # lifecycle event fire with a JS-parity payload (+reason+ + visitor count).
    #
    # On FAILURE (a failed {HttpClient::Response} — story 1.5 returns it WITHOUT
    # raising): the drained visitors are RE-ENQUEUED via {VisitorsQueue#requeue}
    # (preserving per-visitor merge), a +warn+ records the retention, and NO
    # event fires. There is NO inline retry — a frozen divergence from PHP's
    # 3-attempt backoff; the next attempt is the next timer tick or size trigger.
    # The bounded queue (drop-oldest + warn at the 1000 cap) keeps a sustained
    # outage from growing host memory without bound (NFR10).
    #
    # Never raises into the host (NFR9): a +rescue StandardError+ logs and
    # swallows. Note the re-enqueue happens BEFORE the rescue so a transport-layer
    # failed Response retains; a raise from the rescue path itself (after the
    # drain) cannot retain, but the never-crash contract takes precedence there.
    #
    # @param reason [String, nil] a human-readable release reason (logged + fired).
    # @return [void]
    def release_queue(reason = nil)
      # Story 4.4 — the SINGLE fork-safety PID boundary all three flush triggers
      # (explicit flush, size, interval) inherit from one place. A cheap
      # ForkGuard.forked? check (an integer PID comparison — Datadog idiom) covers
      # the Process.daemon path that BYPASSES the _fork hook: a stale process
      # re-arms (marks the inherited dead timers dead, clears the inherited queue,
      # resets owner_pid) BEFORE proceeding. The check fires BEFORE the
      # empty-queue early return so a freshly daemonised process re-arms its
      # timers even when nothing is queued yet.
      guard_fork_boundary

      visitors = @queue.drain!
      return if visitors.empty?

      deliver(visitors, reason)
    rescue StandardError => e
      # Never-crash boundary: a delivery failure must not crash the host.
      @log_manager.error("ApiManager#release_queue: #{e.class}: #{e.message}")
    end

    private

    # POST the drained per-visitor entries and branch on the result. On SUCCESS:
    # an +info+ line + the {SystemEvents::API_QUEUE_RELEASED} lifecycle event. On
    # FAILURE: re-enqueue the drained visitors (preserving the per-visitor merge)
    # and +warn+ — NO event fires (frozen Ruby divergence from JS, which DOES fire
    # on failure — api-manager.ts:247). There is NO inline retry; the next timer
    # tick / size trigger retries (the bounded queue keeps a sustained outage from
    # growing host memory — NFR10). Caller wraps this in the never-crash rescue.
    def deliver(visitors, reason)
      response = post_payload(build_payload(visitors))
      if response.success?
        @log_manager.info(
          "ApiManager#release_queue: queue released, reason=#{reason}, visitors=#{visitors.size}"
        )
        @event_manager.fire(
          SystemEvents::API_QUEUE_RELEASED,
          { "reason" => reason, "visitors" => visitors.size }
        )
      else
        @queue.requeue(visitors)
        @log_manager.warn(
          "ApiManager#release_queue: delivery failed, retaining #{count_events(visitors)} events " \
          "(status #{response.status}), reason=#{reason}"
        )
      end
    end

    # Story 4.4 — the PID-guarded fork boundary. When +ForkGuard.forked?+ is true
    # (a +Process.daemon+ spawn bypassed the +_fork+ hook so owner_pid is stale),
    # run the shared re-arm path before any delivery: it marks both registered
    # timers dead, fires the child-callbacks (this manager's queue-ownership
    # clear), and resets owner_pid — leaving the process behaving like a fresh
    # child. A free no-op in the owning process and on JRuby (forked? is always
    # false there).
    def guard_fork_boundary
      return unless ForkGuard.forked?

      @log_manager.debug(
        "ApiManager#release_queue: stale process detected (fork/daemon bypass), re-arming"
      )
      ForkGuard.rearm!
    end

    # The registered ForkGuard child-callback (Story 4.4): clear this manager's
    # inherited queue so a forked child starts EMPTY and never double-delivers
    # the parent's events. ForkGuard fires this in the child after marking timers
    # dead. Never-crash: a raising callback must not break the fork hook.
    def clear_queue_ownership
      @queue.clear
      @log_manager.debug("ApiManager#clear_queue_ownership: cleared inherited queue ownership in child")
    rescue StandardError => e
      @log_manager.error("ApiManager#clear_queue_ownership: #{e.class}: #{e.message}")
    end

    # Lazily start the flush BackgroundTimer (NFR4 — never in the factory). Called
    # on the first (and every) enqueue; idempotent and re-arms transparently after
    # a fork (2.6 BackgroundTimer#start). A +nil+ flush_interval makes this a
    # guarded no-op — no thread is ever created (timer-off mode).
    def ensure_flush_timer!
      @flush_timer.start
    end

    # The flush-timer tick body: release the queue with reason +"interval"+. Wrapped
    # by BackgroundTimer's never-crash rescue (2.6); {#release_queue} additionally
    # rescues internally so a tick never escapes.
    def flush_tick
      release_queue("interval")
    end

    # Total events across the given per-visitor entries (for the retention warn).
    def count_events(visitors)
      visitors.sum { |entry| entry["events"].size }
    end

    # Build the string-keyed camelCase wire payload (boundary #2). The drained
    # visitor entries are already wire-shaped, so they ride verbatim.
    def build_payload(visitors)
      {
        "accountId" => @data_manager.account_id,
        "projectId" => @data_manager.project_id,
        "enrichData" => ENRICH_DATA,
        "source" => SOURCE,
        "visitors" => visitors
      }
    end

    # POST the payload to the project-scoped track URL through the HTTP port and
    # return the frozen {HttpClient::Response}. The port serializes the body with
    # +JSON.generate+, applies the ConvertAgent UA, and strips a Bearer header on a
    # non-HTTPS endpoint. The port NEVER raises — a transport failure comes back as
    # a failed Response (+success? == false+), so the caller branches on the result.
    def post_payload(payload)
      @http_client.request(method: :post, url: track_url, headers: auth_headers, body: payload)
    end

    # +{track_endpoint with [project_id] replaced}/track/{sdkKey}+ — JS
    # api-manager.ts:221-229. The +sdk_key+ falls back to +"{accountId}/{projectId}"+
    # when none is configured (JS +config?.sdkKey || `${accountId}/${projectId}`+).
    def track_url
      base = @config.track_endpoint.to_s.gsub("[project_id]", @data_manager.project_id.to_s)
      "#{base}/track/#{sdk_key}"
    end

    # The SDK key path segment, with the JS account/project fallback.
    def sdk_key
      @config.sdk_key || "#{@data_manager.account_id}/#{@data_manager.project_id}"
    end

    # An +Authorization: Bearer {secret}+ header VALUE when a secret is configured,
    # else none. The port owns the UA / HTTPS / plaintext-stripping mechanics.
    def auth_headers
      secret = @config.sdk_key_secret
      return {} if secret.nil?

      { "Authorization" => "Bearer #{secret}" }
    end
  end
end
