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
require_relative "convert_sdk/http_client"
require_relative "convert_sdk/stores/memory_store"
require_relative "convert_sdk/stores/redis_store"
require_relative "convert_sdk/data_store_manager"
require_relative "convert_sdk/event_manager"
require_relative "convert_sdk/data_manager"
require_relative "convert_sdk/client"

# The Convert Experiences full-stack SDK for Ruby.
#
# {ConvertSdk.create} is THE public entry point (frozen API name): it builds the
# validated {Config}, wires the managers, and returns a ready-to-use {Client}.
module ConvertSdk
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
  # @param options [Hash{Symbol=>Object}] any other {Config::DEFAULTS} option
  #   (+sdk_key_secret+, +environment+, +log_level+, timeouts, …).
  # @raise [ArgumentError] on misconfiguration (missing sdk_key+data, bad types,
  #   unknown option) — the only exception {create} lets escape.
  # @return [Client] the wired SDK client.
  def self.create(sdk_key: nil, data: nil, store: nil, **options)
    config_options = options.merge(sdk_key: sdk_key, data: data)
    log_manager = LogManager.new(level: options.fetch(:log_level, Config::DEFAULTS[:log_level]))
    config = Config.new(log_manager: log_manager, **config_options)

    http_client = HttpClient.new(
      log_manager: log_manager,
      open_timeout: config.open_timeout,
      read_timeout: config.read_timeout
    )
    data_store_manager = DataStoreManager.new(log_manager: log_manager, store: store)
    event_manager = EventManager.new(log_manager: log_manager)
    data_manager = DataManager.new(log_manager: log_manager)

    Client.new(
      config: config,
      log_manager: log_manager,
      http_client: http_client,
      data_store_manager: data_store_manager,
      event_manager: event_manager,
      data_manager: data_manager
    )
  end
end
