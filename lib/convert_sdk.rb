# frozen_string_literal: true

require_relative "convert_sdk/version"
require_relative "convert_sdk/murmur_hash3"
require_relative "convert_sdk/sentinel"
require_relative "convert_sdk/enums/rule_error"
require_relative "convert_sdk/enums/bucketing_error"
require_relative "convert_sdk/enums/feature_status"
require_relative "convert_sdk/enums/log_level"
require_relative "convert_sdk/enums/system_events"
require_relative "convert_sdk/enums/goal_data_key"
require_relative "convert_sdk/bucketed_variation"
require_relative "convert_sdk/bucketed_feature"
require_relative "convert_sdk/redactor"
require_relative "convert_sdk/log_manager"
require_relative "convert_sdk/config_validator"
require_relative "convert_sdk/config"
require_relative "convert_sdk/bucketing_manager"
require_relative "convert_sdk/comparisons"
require_relative "convert_sdk/rule_manager"
require_relative "convert_sdk/http_client"
require_relative "convert_sdk/stores/memory_store"
require_relative "convert_sdk/stores/redis_store"
require_relative "convert_sdk/data_store_manager"
require_relative "convert_sdk/event_manager"
require_relative "convert_sdk/fork_guard"
require_relative "convert_sdk/background_timer"
require_relative "convert_sdk/data_manager"
require_relative "convert_sdk/visitors_queue"
require_relative "convert_sdk/experience_manager"
require_relative "convert_sdk/feature_manager"
require_relative "convert_sdk/segments_manager"
require_relative "convert_sdk/context"
require_relative "convert_sdk/client"

# Install the SDK's only global mutation — the Process._fork prepend — at load
# (it must exist before any fork; installing it is cheap and thread-free, so it
# respects the NFR4 zero-threads-until-use rule, which concerns THREADS, not the
# hook). A no-op on JRuby by construction.
ConvertSdk::ForkGuard.install!

# The Convert Experiences full-stack SDK for Ruby.
#
# {ConvertSdk.create} is THE public entry point (frozen API name): it builds the
# validated {Config}, wires the managers, and returns a ready-to-use {Client}.
module ConvertSdk
  # The default config-cache TTL in seconds, used by the timer-off (Lambda/CLI)
  # decision-time staleness check when +data_refresh_interval+ is +nil+
  # (timer-off ≠ TTL-off). 300s converges on the same cadence the background
  # timer uses, on demand. A Ruby-SDK design constant (PHP on-demand TTL
  # semantics) — the JS SDK has no timer-off TTL concept. See Story 2.7.
  DEFAULT_CONFIG_TTL = 300

  # The SDK's base error type. Note the SDK has NO custom exception hierarchy for
  # runtime/infra failures (Decision 3 — it degrades gracefully with cached
  # config / sentinels); misconfiguration surfaces as a plain +ArgumentError+
  # from {Config}. This type exists only as a namespace anchor.
  class Error < StandardError; end

  # Build an SDK client from an SDK key (live config fetch) or a pre-fetched
  # +data:+ object (direct data mode). THE public entry point.
  #
  # Wiring order: a {LogManager} is built first, then {Config} (which registers
  # any +sdk_key+ / +sdk_key_secret+ with the manager's Redactor before any log
  # line can carry them and raises +ArgumentError+ on misconfiguration — the
  # SDK's only raising surface), then the {HttpClient}, {DataStoreManager},
  # {EventManager}, and {DataManager} ports, then the {Client} (which fetches /
  # installs config and fires +ready+). No background threads are started here
  # (NFR4 — lazy start; the refresh / flush timers are wired by their own
  # stories).
  #
  # @param sdk_key [String, nil] the account/project SDK key (fetch mode).
  # @param data [Hash, nil] a pre-fetched config object (direct data mode); when
  #   supplied, no fetch occurs.
  # @param store [Object, nil] an optional duck-typed data store (get/set);
  #   defaults to an in-memory store.
  # @param clock [#call, nil] an optional monotonic time source (seconds) for
  #   the config-cache TTL math (Story 2.7); defaults to the SDK's monotonic
  #   clock. Injectable so tests control staleness without real waits. NOT a
  #   {Config} option — extracted here before validation.
  # @param options [Hash{Symbol=>Object}] any other {Config::DEFAULTS} option
  #   (+sdk_key_secret+, +environment+, +log_level+, timeouts, …).
  # @raise [ArgumentError] on misconfiguration (missing sdk_key+data, bad types,
  #   unknown option) — the only exception {create} lets escape.
  # @return [Client] the wired SDK client.
  def self.create(sdk_key: nil, data: nil, store: nil, clock: nil, **options)
    config_options = options.merge(sdk_key: sdk_key, data: data)
    log_manager = LogManager.new(level: options.fetch(:log_level, Config::DEFAULTS[:log_level]))
    # Wire the ForkGuard re-arm logger (Story 2.7) so fork-detection debug lines
    # flow through the redacting LogManager. nil-safe before wiring.
    ForkGuard.logger = log_manager
    config = Config.new(log_manager: log_manager, **config_options)

    http_client = HttpClient.new(
      log_manager: log_manager,
      open_timeout: config.open_timeout,
      read_timeout: config.read_timeout
    )
    data_store_manager = DataStoreManager.new(log_manager: log_manager, store: store)
    event_manager = EventManager.new(log_manager: log_manager)
    data_manager = build_data_manager(config, log_manager, data_store_manager, clock)

    Client.new(
      config: config,
      log_manager: log_manager,
      http_client: http_client,
      data_store_manager: data_store_manager,
      event_manager: event_manager,
      data_manager: data_manager
    )
  end

  # Build the {DataManager} wired with the Story 2.7 config-cache surface: the
  # cache lives under +convert_sdk.config.{sdkKey}+ (the DataManager writes
  # through on every install and runs the timer-off TTL check against it). A nil
  # sdk_key (direct-data mode) leaves the cache key nil, so no cache write
  # happens. The +clock+ (monotonic TTL source) is injected only when supplied.
  # @api private
  def self.build_data_manager(config, log_manager, data_store_manager, clock)
    config_key = config.sdk_key.nil? ? nil : data_store_manager.config_key(config.sdk_key)
    clock_option = clock.nil? ? {} : { clock: clock } #: Hash[Symbol, ^() -> Float]
    DataManager.new(
      log_manager: log_manager,
      data_store_manager: data_store_manager,
      config_key: config_key,
      ttl: config.data_refresh_interval,
      **clock_option
    )
  end
  private_class_method :build_data_manager
end
