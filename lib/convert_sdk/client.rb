# frozen_string_literal: true

require "uri"

module ConvertSdk
  # The SDK runtime handle returned by {ConvertSdk.create}.
  #
  # +Client+ owns the wiring of the injected managers (config, logging, HTTP,
  # store, events, data) and drives the config lifecycle at construction:
  #
  # * *Direct data mode* (+data:+ supplied) — the inline object is normalised to
  #   string keys and installed straight into {DataManager}; NO config fetch
  #   happens (a single network-free path for testing / advanced setups).
  # * *Fetch mode* (+sdk_key:+ only) — config is fetched via
  #   +GET {config_endpoint}/config/{sdkKey}+ (+?environment=...+ when set)
  #   through {HttpClient} ONLY, with +Authorization: Bearer {sdk_key_secret}+
  #   attached when a secret is configured. A failed fetch is logged at +warn+
  #   and the client is constructed WITHOUT config (degrade-gracefully, NFR12) —
  #   it never raises.
  #
  # == ready exactly once (FR9)
  #
  # The first successful config install (fetched OR direct) fires
  # {SystemEvents::READY} exactly once for the client's lifetime; the once-guard
  # is the +:first+ marker {DataManager#install_config} computes atomically inside
  # its config mutex. Subsequent installs (Story 2.7's refresh) fire
  # {SystemEvents::CONFIG_UPDATED}, never +ready+ again.
  #
  # == Never-crash boundary
  #
  # Every public method rescues +StandardError+, logs it, and returns its
  # per-contract value — only {ConvertSdk.create}'s +ArgumentError+ (raised by
  # {Config} on misconfiguration) is allowed to escape. The endpoints are touched
  # ONLY through {HttpClient} (the single hardened HTTP port); the Client never
  # touches the network library directly or builds wire headers beyond passing
  # the Bearer header VALUE through the port.
  #
  # == Forward surface (deliberately minimal)
  #
  # {#create_context} is a stub here — the full Context decisioning lands in
  # Story 2.8. No background threads are started by the Client or the factory
  # (NFR4 lazy start); the refresh timer (Story 2.7), flush/fork/at_exit (Epic 4)
  # wiring lands in those stories. Constructor injection throughout — no globals.
  class Client
    # @param config [Config] the validated configuration surface.
    # @param log_manager [LogManager] shared logging surface (secrets armed).
    # @param http_client [HttpClient] the single HTTP port (config fetch only here).
    # @param data_store_manager [DataStoreManager] persistence port (wired; config
    #   caching is Story 2.7 — in-memory install only here).
    # @param event_manager [EventManager] lifecycle pub/sub (fires +ready+).
    # @param data_manager [DataManager] holds the deep-frozen config snapshot.
    def initialize(config:, log_manager:, http_client:, data_store_manager:,
                   event_manager:, data_manager:)
      @config = config
      @log_manager = log_manager
      @http_client = http_client
      @data_store_manager = data_store_manager
      @event_manager = event_manager
      @data_manager = data_manager
      # The lazily-started config-refresh BackgroundTimer (Story 2.7). Created
      # here (interval bound, registered with ForkGuard) but NEVER started in the
      # factory — #ensure_refresh_timer! starts it on first decision-path use
      # (NFR4). A nil data_refresh_interval makes #start a guarded no-op (2.6),
      # so timer-off mode never spawns a thread.
      @refresh_timer = build_refresh_timer
      # Wire the synchronous timer-off refresh callable into the DataManager so
      # its decision-time TTL check (#ensure_fresh_config!) runs one full refresh
      # cycle through the single HTTP port (the I/O happens under DataManager's
      # thundering-herd fetch mutex, never the config mutex).
      @data_manager.refetch = -> { refresh_config }
      bootstrap_config
    rescue StandardError => e
      # Construction must never crash the host: log and continue config-less.
      @log_manager.error("Client#initialize: #{e.class}: #{e.message}")
    end

    # @return [Config] the configuration this client was built with.
    attr_reader :config

    # @return [DataManager] the config snapshot reader surface.
    attr_reader :data_manager

    # Subscribe to a lifecycle event. Public API; delegates to {EventManager#on}
    # (which normalises {SystemEvents} constants and matching strings to one key
    # and replays deferred one-shot events to late subscribers).
    #
    # @param event [String] a {SystemEvents} value or matching string.
    # @yieldparam payload [Object, nil]
    # @yieldparam err [Object, nil]
    # @return [self]
    def on(event, &)
      @event_manager.on(event, &)
      self
    rescue StandardError => e
      @log_manager.error("Client#on: #{e.class}: #{e.message}")
      self
    end

    # @return [Boolean] true once a config snapshot is installed (degrade probe).
    def config_available?
      @data_manager.config_available?
    end

    # Create a per-visitor decisioning {Context} — the object an integrator holds
    # for the lifetime of one request/job.
    #
    # The +visitor_id+ is validated for presence (blank/nil → an +error+ log line
    # + +nil+ return, NOT an +ArgumentError+: validation here is request-time, and
    # the never-crash contract forbids raising into the host on a per-request call;
    # only {ConvertSdk.create}'s config-time misconfiguration raises). Creation is
    # the SDK's "first use" trigger, so it fires the lazy-start refresh-timer hook
    # ({#ensure_refresh_timer!}, NFR4) — no threads start before the first context.
    #
    # Each call returns a NEW, independent {Context} (no caching, no shared mutable
    # in-memory visitor state across instances — FR12); contexts for the same
    # visitor share only the store-backed {StoreData} (stickiness). Attributes are
    # deep-stringified at the {Context} boundary.
    #
    # @param visitor_id [String] the visitor id (must be non-blank).
    # @param attributes [Hash, nil] optional per-visitor attributes.
    # @return [Context, nil] the new Context, or nil for a blank visitor id.
    def create_context(visitor_id = nil, attributes = nil)
      if visitor_id.nil? || (visitor_id.respond_to?(:strip) && visitor_id.strip.empty?)
        @log_manager.error("Client#create_context: blank visitor_id; returning nil")
        return nil
      end

      # Context creation is "first use" — lazily arm the background refresh timer.
      ensure_refresh_timer!
      Context.new(
        visitor_id: visitor_id,
        attributes: attributes,
        data_manager: @data_manager,
        data_store_manager: @data_store_manager,
        event_manager: @event_manager,
        log_manager: @log_manager,
        config: @config
      )
    rescue StandardError => e
      @log_manager.error("Client#create_context: #{e.class}: #{e.message}")
      nil
    end

    # Lazily start the background config-refresh timer (NFR4 — never in the
    # factory). Called at the first decision-path entry (consumed by 2.8/2.11);
    # idempotent (2.6 {BackgroundTimer#start} is idempotent and re-arms after a
    # fork). A nil +data_refresh_interval+ makes this a guarded no-op (no thread
    # is ever created — timer-off mode). Never raises into the host.
    # @return [self]
    def ensure_refresh_timer!
      @refresh_timer.start
      self
    rescue StandardError => e
      @log_manager.error("Client#ensure_refresh_timer!: #{e.class}: #{e.message}")
      self
    end

    # Decision-time freshness hook for timer-off mode (Lambda/CLI). Delegates to
    # {DataManager#ensure_fresh_config!}, which performs an on-demand TTL check
    # and a synchronous, thundering-herd-guarded refetch when the cached config
    # is stale. A no-op when the refresh timer is enabled. Never raises.
    # @return [self]
    def ensure_fresh_config!
      @data_manager.ensure_fresh_config!
      self
    rescue StandardError => e
      @log_manager.error("Client#ensure_fresh_config!: #{e.class}: #{e.message}")
      self
    end

    private

    # Build the config-refresh BackgroundTimer bound to +data_refresh_interval+
    # and register it with ForkGuard (so a forked child marks it dead and the
    # next #ensure_refresh_timer! re-arms it). The tick body is {#refresh_config}.
    def build_refresh_timer
      timer = BackgroundTimer.new(
        interval: @config.data_refresh_interval,
        log_manager: @log_manager,
        name: "refresh"
      ) { refresh_config }
      ForkGuard.register_timer(timer)
      timer
    end

    # One refresh cycle (the timer tick AND the synchronous timer-off refetch
    # share this path): refetch through the HTTP port and, on success, install
    # (deep-freeze + atomic swap + cache write via DataManager) which fires
    # +config.updated+ (never +ready+ again — the 2.5 ready-once guard). A failed
    # refetch keeps the current snapshot, warns, and lets the timer retry on the
    # next tick (no inline retry, no backoff — frozen decision).
    def refresh_config
      envelope = refetch_config
      if envelope.is_a?(Hash)
        install(envelope, "Client#refresh_config: refreshed config installed")
      else
        @log_manager.warn("Client#refresh_config: refresh failed, serving cached config")
      end
    end

    # Refetch the config through the single HTTP port and return the parsed
    # envelope on success, or nil on any failed response. The single network
    # refetch primitive — used by the timer tick and the timer-off synchronous
    # refresh; the I/O here never holds the config mutex.
    def refetch_config
      response = @http_client.request(method: :get, url: config_url, headers: fetch_headers)
      response.success? && response.body.is_a?(Hash) ? response.body : nil
    end

    # Drive the config lifecycle at construction: direct-data install when a
    # +data:+ object was supplied, otherwise a live fetch. Either path that
    # yields a usable config installs it identically (and fires +ready+ once).
    def bootstrap_config
      if @config.data.nil?
        fetch_and_install_config
      else
        install(@config.data, "Client#initialize: installed direct data config")
      end
    end

    # Fetch config through the HTTP port and install it on success. A failed
    # response degrades gracefully: it MAY fall back to a non-stale cached entry
    # from the store (meaningful across processes with a shared store like
    # Redis), otherwise a +warn+ line, no config, no raise.
    def fetch_and_install_config
      response = @http_client.request(method: :get, url: config_url, headers: fetch_headers)
      if response.success? && response.body.is_a?(Hash)
        install(response.body, "Client#initialize: installed fetched config")
      elsif @data_manager.install_from_cache_if_fresh
        @event_manager.fire(SystemEvents::READY, deferred: true)
      else
        @log_manager.warn(
          "Client#initialize: config fetch failed (status #{response.status}); " \
          "continuing without config"
        )
      end
    end

    # Install a config envelope and fire the correct lifecycle event based on the
    # atomic first/updated marker from {DataManager}. Symbol-keyed inputs (direct
    # data mode) are normalised to string keys at this public boundary before
    # install so readers see the same string-keyed wire shape as fetched config.
    def install(source, log_message)
      marker = @data_manager.install_config(stringify_keys(source))
      return unless marker

      @log_manager.info(log_message)
      if marker == :first
        @event_manager.fire(SystemEvents::READY, deferred: true)
      else
        @event_manager.fire(SystemEvents::CONFIG_UPDATED)
      end
    end

    # Build the config-fetch URL: +{config_endpoint}/config/{sdkKey}+ with an
    # +environment+ query parameter appended only when one is configured.
    def config_url
      url = "#{@config.config_endpoint}/config/#{@config.sdk_key}"
      env = @config.environment
      return url if env.nil?

      "#{url}?environment=#{URI.encode_www_form_component(env)}"
    end

    # The fetch headers: an +Authorization: Bearer {secret}+ value when a secret
    # is configured, else none. The port (HttpClient) owns UA / HTTPS / Bearer
    # plaintext-stripping mechanics — the Client only supplies the header VALUE.
    def fetch_headers
      secret = @config.sdk_key_secret
      return {} if secret.nil?

      { "Authorization" => "Bearer #{secret}" }
    end

    # Recursively normalise a (possibly symbol-keyed) config object to string
    # keys — the public-boundary normalisation for direct data mode, so the
    # installed snapshot matches the string-keyed fetched wire shape exactly.
    def stringify_keys(node)
      case node
      when Hash
        result = {} #: Hash[String, untyped]
        node.each { |k, v| result[k.to_s] = stringify_keys(v) }
        result
      when Array
        node.map { |element| stringify_keys(element) }
      else
        node
      end
    end
  end
end
