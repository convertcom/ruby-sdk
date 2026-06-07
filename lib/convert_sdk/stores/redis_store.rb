# frozen_string_literal: true

require "json"

module ConvertSdk
  module Stores
    # A first-party, in-tree store adapter backed by Redis — the cross-process
    # answer to {MemoryStore}'s per-process limitation.
    #
    # == Why Redis (FR49)
    #
    # {MemoryStore} keeps state in a single process. Puma clusters, Sidekiq
    # worker fleets, and Lambda invocations each run in separate processes, so
    # sticky bucketing (Story 2.11) and goal deduplication (Story 4.3) that
    # round-trip through a +MemoryStore+ are inconsistent across the fleet.
    # +RedisStore+ shares that state through a Redis instance, giving every
    # process the same view.
    #
    # == Zero gemspec footprint
    #
    # The +redis+ gem is the *user's* dependency, never the SDK's: it is NOT a
    # gemspec runtime dependency and is +require+-d *lazily* inside {#initialize}
    # — and only when a client is built from connection options. Requiring this
    # file (which +lib/convert_sdk.rb+ does unconditionally) therefore never
    # pulls in +redis+, so +require "convert_sdk"+ stays green for users who do
    # not install it. If a caller asks +RedisStore+ to build its own client
    # without +redis+ installed, instantiation raises an actionable error naming
    # the gem to add — a wiring-time programmer error, sanctioned in the same
    # class as +ConvertSdk.create+'s argument validation, NOT a business path.
    #
    # == Construction
    #
    #   # Preferred: inject an existing client (connection reuse / pooling).
    #   # No `require "redis"`, no `Redis.new` — works even where the adapter
    #   # file is loaded without the gem present.
    #   store = ConvertSdk::Stores::RedisStore.new(redis: Redis.new(url: ...))
    #
    #   # Or pass connection options; the adapter lazily requires `redis` and
    #   # constructs the client itself.
    #   store = ConvertSdk::Stores::RedisStore.new(url: "redis://localhost:6379/0")
    #
    # An optional +key_prefix+ namespaces every key (default +"convert:"+) so the
    # SDK's keys do not collide with other tenants of the same Redis database.
    #
    # == Thin adapter — resilience lives upstream
    #
    # This adapter is serialization + connection only. It does NOT rescue Redis
    # client exceptions: {DataStoreManager} (Story 2.1) already wraps every
    # +get+/+set+ in a rescue-log passthrough, degrading a raising store to
    # +nil+/no-op instead of crashing the host. Duplicating that rescue here
    # would swallow errors the manager is responsible for logging.
    #
    # == Cross-process consistency caveat
    #
    # Visitor-data merges are a read-modify-write. In-process that sequence is
    # atomic under {DataStoreManager}'s mutex, but across processes sharing one
    # Redis there is no such lock: concurrent writers race and the last write
    # wins. This matches the JS SDK contract. The SDK does NOT use Lua scripts
    # or +WATCH+/+MULTI+ to close that race — that is deliberately out of scope.
    #
    # Sidekiq / Lambda deployment guidance: see the Epic 5 documentation.
    class RedisStore
      # Default namespace prepended to every key written to Redis.
      DEFAULT_KEY_PREFIX = "convert:"

      # @param redis [Object, nil] an existing redis-rb-compatible client
      #   responding to +#get+/+#set+. When supplied, +redis+ is NOT required and
      #   no new client is constructed (preferred — enables connection reuse).
      # @param key_prefix [String] namespace prepended to every key
      #   (default +"convert:"+).
      # @param options [Hash] connection options (e.g. +url:+) forwarded to
      #   +Redis.new+ when no +redis:+ client is injected. Triggers the lazy
      #   +require "redis"+.
      # @raise [LoadError] re-raised as an actionable error when +redis:+ is
      #   omitted and the +redis+ gem is not installed.
      def initialize(redis: nil, key_prefix: DEFAULT_KEY_PREFIX, **options)
        @key_prefix = key_prefix
        @client = redis || build_client(options)
      end

      # Read and deserialize the value stored under +key+.
      #
      # @param key [String] the (unprefixed) lookup key.
      # @return [Object, nil] the JSON-parsed value (string-keyed hashes,
      #   numbers, arrays, booleans), or +nil+ when the key is absent.
      def get(key)
        raw = @client.get(namespaced(key))
        raw.nil? ? nil : JSON.parse(raw)
      end

      # Serialize +value+ to JSON and store it under +key+, overwriting any
      # existing value.
      #
      # @param key [String] the (unprefixed) storage key.
      # @param value [Object] a JSON-serializable value (StoreData shape).
      # @return [Object] the client's +set+ return value.
      def set(key, value)
        @client.set(namespaced(key), JSON.generate(value))
      end

      private

      # Lazily require the +redis+ gem and construct a client from +options+.
      # Called ONLY when no client was injected; this is the single site that
      # depends on the gem being installed.
      #
      # @param options [Hash] connection options forwarded to +Redis.new+.
      # @return [Object] a new redis-rb client.
      # @raise [LoadError] with an actionable message when the gem is absent.
      def build_client(options)
        require "redis"
        Redis.new(**options)
      rescue LoadError
        raise LoadError,
              "RedisStore requires the 'redis' gem — add `gem 'redis'` to your Gemfile " \
              "(or inject an existing client via `redis:`)."
      end

      # @param key [String] the unprefixed key.
      # @return [String] the key with the configured namespace prepended.
      def namespaced(key)
        "#{@key_prefix}#{key}"
      end
    end
  end
end
