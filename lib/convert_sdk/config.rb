# frozen_string_literal: true

module ConvertSdk
  # The SDK's configuration surface and wire-translation boundary #1.
  #
  # +Config+ is the ONE place in the gem where the inbound public naming world
  # (idiomatic snake_case keyword arguments) is translated into the internal /
  # wire naming world (string-keyed camelCase). The only other naming-world
  # conversion site in the entire gem is the outbound payload builder in
  # ApiManager (Story 4.1); any other file converting option names is an
  # architecture violation (the two-worlds rule).
  #
  # == JS-parity defaults
  #
  # {DEFAULTS} carries the frozen JS-parity values — batch 10, flush interval
  # 1s, data-refresh 300s, bucketing seed 9999 / max-traffic 10000 / max-hash
  # 2**32. These exact numbers are restated across the PRD, architecture, and
  # research; they are NOT tuning knobs and must not drift. Endpoint URLs are
  # copied verbatim from the reference SDKs' default config.
  #
  # == Fail-fast validation (the SDK's only raising surface)
  #
  # Construction delegates to {ConfigValidator}, which raises a stdlib
  # +ArgumentError+ — naming the offending option and the expected type — for any
  # presence/type violation. This is the SDK's ONLY raising surface (Decision 3):
  # there is no custom exception hierarchy, because the SDK degrades gracefully
  # (cached config / sentinels) for every runtime/infra failure, leaving nothing
  # for a hierarchy to hold. Misconfiguration therefore surfaces immediately at
  # boot rather than as silent misbehavior in production. Unknown option keys are
  # rejected for the same reason — a typo fails fast instead of being ignored.
  #
  # == Nil-able timer intervals (Lambda / CLI mode)
  #
  # +flush_interval+ and +data_refresh_interval+ accept +nil+, meaning
  # timer-off: the background flush / refresh threads are never started. This is
  # the AWS Lambda and plain-CLI recipe (synchronous flush before exit; no
  # background threads). +flush_interval+ is the canonical flush-timer key
  # throughout the gem (the older +event_release_interval+ alias is retired).
  #
  # == Secret registration (NFR5)
  #
  # When an +sdk_key+ / +sdk_key_secret+ is present and a {LogManager} is
  # injected, +Config+ registers those values with the manager's {Redactor}
  # immediately at construction — so secrets are armed before any log line can
  # carry them. +Config+ is constructible standalone (no +log_manager+) for unit
  # tests; +ConvertSdk.create+ / Client (Story 2.5) injects the real manager.
  class Config
    # Number of milliseconds per second — the +flush_interval+ second→ms wire
    # translation factor.
    MILLISECONDS_PER_SECOND = 1000

    # The fixed bucketing hash space (2**32). A JS-parity constant, not a
    # configurable option — exposed as a reader for the bucketing engine.
    MAX_HASH = 4_294_967_296

    # The frozen JS-parity defaults for every public option. Verified against
    # javascript-sdk +config/default.ts+ and php-sdk +DefaultConfig.php+.
    DEFAULTS = {
      # Auth / data — at least one of sdk_key / data is required (validated).
      sdk_key: nil,
      sdk_key_secret: nil,
      data: nil,
      # Platform environment selector; nil leaves it to the platform default.
      environment: nil,
      # Live Convert endpoints (verbatim from the reference default config).
      config_endpoint: "https://cdn-4.convertexperiments.com/api/v1",
      track_endpoint: "https://[project_id].metrics.convertexperiments.com/v1",
      # Bucketing constants — frozen JS-parity numbers, do not tune.
      max_traffic: 10_000,
      hash_seed: 9999,
      # Config-refresh cadence in seconds (JS 300000 ms); nil = timer-off.
      data_refresh_interval: 300,
      # Event delivery — batch size and flush cadence (seconds); nil = timer-off.
      event_batch_size: 10,
      flush_interval: 1,
      # Rule evaluation options.
      keys_case_sensitive: true,
      negation: "!",
      # Logging verbosity (JS default.ts:29 logLevel: LogLevel.DEBUG).
      log_level: LogLevel::DEBUG,
      # Network tracking enable/disable.
      tracking: true,
      # HTTP client timeouts in seconds (consumed by HttpClient, Story 1.5).
      open_timeout: 5,
      read_timeout: 10
    }.freeze

    # @!attribute [r] sdk_key
    #   @return [String, nil] account/project SDK key (JS +sdkKey+). Path auth.
    # @!attribute [r] sdk_key_secret
    #   @return [String, nil] bearer secret (JS +sdkKeySecret+). Redacted.
    # @!attribute [r] data
    #   @return [Hash, nil] inline config payload (JS +data+); skips fetch.
    # @!attribute [r] environment
    #   @return [String, nil] platform environment (JS +environment+).
    # @!attribute [r] config_endpoint
    #   @return [String] config-fetch base URL (JS +api.endpoint.config+).
    # @!attribute [r] track_endpoint
    #   @return [String] tracking base URL (JS +api.endpoint.track+).
    # @!attribute [r] max_traffic
    #   @return [Integer] bucketing max traffic (JS +bucketing.max_traffic+).
    # @!attribute [r] hash_seed
    #   @return [Integer] bucketing hash seed (JS +bucketing.hash_seed+).
    # @!attribute [r] data_refresh_interval
    #   @return [Numeric, nil] config-refresh seconds; nil = timer-off
    #     (JS +dataRefreshInterval+, ms).
    # @!attribute [r] event_batch_size
    #   @return [Integer] event flush batch size (JS +events.batch_size+).
    # @!attribute [r] flush_interval
    #   @return [Numeric, nil] flush cadence seconds; nil = timer-off
    #     (JS +events.release_interval+, ms). Canonical flush-timer key.
    # @!attribute [r] keys_case_sensitive
    #   @return [Boolean] rule key case sensitivity (JS +rules.keys_case_sensitive+).
    # @!attribute [r] negation
    #   @return [String] rule negation token (JS +rules.negation+, default "!").
    # @!attribute [r] log_level
    #   @return [Integer] a {LogLevel} threshold (JS +logger.logLevel+).
    # @!attribute [r] tracking
    #   @return [Boolean] network tracking enabled (JS +network.tracking+).
    # @!attribute [r] open_timeout
    #   @return [Numeric] HTTP connect timeout seconds (HttpClient, NFR3).
    # @!attribute [r] read_timeout
    #   @return [Numeric] HTTP read timeout seconds (HttpClient, NFR3).
    attr_reader :sdk_key, :sdk_key_secret, :data, :environment,
                :config_endpoint, :track_endpoint, :max_traffic, :hash_seed,
                :data_refresh_interval, :event_batch_size, :flush_interval,
                :keys_case_sensitive, :negation, :log_level, :tracking,
                :open_timeout, :read_timeout

    # Build a validated configuration from snake_case keyword options merged over
    # {DEFAULTS}. Raises +ArgumentError+ (the SDK's only raising surface) on any
    # presence/type violation or unknown option key.
    #
    # @param log_manager [LogManager, nil] when provided, present secrets
    #   (sdk_key / sdk_key_secret) are registered with its {Redactor} so they
    #   are armed before any log line. Optional for standalone construction.
    # @param options [Hash{Symbol=>Object}] any subset of the {DEFAULTS} keys.
    # @raise [ArgumentError] on unknown keys, missing sdk_key+data, or bad types.
    def initialize(log_manager: nil, **options)
      reject_unknown_keys(options)
      merged = DEFAULTS.merge(options)
      assign(merged)
      ConfigValidator.new(merged).validate!
      register_secrets(log_manager)
    end

    # @return [Integer] the fixed bucketing hash space (2**32).
    def max_hash
      MAX_HASH
    end

    # The wire-translation boundary: the internal, string-keyed camelCase
    # representation downstream managers (DataManager / ApiManager) consume. This
    # is the single inbound conversion site. +flush_interval+ seconds are
    # translated to the millisecond wire value here; nil passes through (timer-off).
    #
    # @return [Hash{String=>Object}] a frozen internal config snapshot.
    def to_internal
      {
        "sdkKey" => @sdk_key,
        "sdkKeySecret" => @sdk_key_secret,
        "data" => @data,
        "environment" => @environment,
        "configEndpoint" => @config_endpoint,
        "trackEndpoint" => @track_endpoint,
        "maxTraffic" => @max_traffic,
        "hashSeed" => @hash_seed,
        "maxHash" => MAX_HASH,
        "dataRefreshInterval" => @data_refresh_interval,
        "batchSize" => @event_batch_size,
        "releaseInterval" => to_milliseconds(@flush_interval),
        "keysCaseSensitive" => @keys_case_sensitive,
        "negation" => @negation,
        "logLevel" => @log_level,
        "tracking" => @tracking
      }.freeze
    end

    # The canonical set of accepted option keys (the {DEFAULTS} keys).
    KNOWN_KEYS = DEFAULTS.keys.freeze

    private

    # Copy every merged option into its like-named instance variable.
    def assign(merged)
      merged.each { |key, value| instance_variable_set("@#{key}", value) }
    end

    # Reject any option key not in {KNOWN_KEYS} — a typo fails fast at boot.
    def reject_unknown_keys(options)
      unknown = options.keys - KNOWN_KEYS
      return if unknown.empty?

      raise ArgumentError, "unknown configuration option(s): #{unknown.join(", ")}"
    end

    # Translate a seconds interval to the millisecond wire value; nil passes
    # through unchanged (timer-off).
    def to_milliseconds(seconds)
      return nil if seconds.nil?

      seconds * MILLISECONDS_PER_SECOND
    end

    # Arm the Redactor with present secrets so no log line can leak them. A nil
    # log_manager (standalone construction) is a no-op.
    def register_secrets(log_manager)
      return if log_manager.nil?

      log_manager.register_secret(@sdk_key) unless @sdk_key.nil?
      log_manager.register_secret(@sdk_key_secret) unless @sdk_key_secret.nil?
    end
  end
end
