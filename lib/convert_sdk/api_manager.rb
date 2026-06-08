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
    end

    # @return [VisitorsQueue] the underlying per-visitor event queue.
    attr_reader :queue

    # Enqueue one wire-shaped event for a visitor (delegates to the queue's
    # per-visitor merge). Pure in-memory — never blocks the caller on I/O.
    #
    # @param visitor_id [String] the visitor the event belongs to.
    # @param event [Hash{String=>Object}] a wire-shaped event hash.
    # @param segments [Hash{String=>Object}, nil] report-segments, attached only
    #   when this enqueue first creates the visitor's queue entry.
    # @return [void]
    def enqueue(visitor_id, event, segments: nil)
      @queue.enqueue(visitor_id, event, segments: segments)
    end

    # Release the queue: drain-and-swap INSIDE the queue lock, then build the wire
    # payload and POST it OUTSIDE the lock. An empty queue is a no-op. A failed
    # POST is logged, never raised (Story 4.2 owns retention).
    #
    # @param reason [String, nil] a human-readable release reason (logged).
    # @return [void]
    def release_queue(reason = nil)
      visitors = @queue.drain!
      return if visitors.empty?

      response = post_payload(build_payload(visitors))
      if response.success?
        @log_manager.info(
          "ApiManager#release_queue: queue released, reason=#{reason}, visitors=#{visitors.size}"
        )
        @event_manager.fire(SystemEvents::API_QUEUE_RELEASED, { "reason" => reason })
      else
        # A failed delivery is logged and surfaced on the lifecycle event with the
        # failure status (JS parity — api-manager.ts:240-251 fires with the error).
        # The queue was already drained; the failed-POST RETENTION path lands in
        # Story 4.2 — this story only guarantees no raise and an accurate signal.
        @log_manager.warn(
          "ApiManager#release_queue: delivery failed (status #{response.status}), reason=#{reason}"
        )
        @event_manager.fire(SystemEvents::API_QUEUE_RELEASED, { "reason" => reason }, response.status)
      end
    rescue StandardError => e
      # Never-crash boundary: a delivery failure must not crash the host.
      @log_manager.error("ApiManager#release_queue: #{e.class}: #{e.message}")
    end

    private

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
