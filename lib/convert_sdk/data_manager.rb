# frozen_string_literal: true

require "json"

module ConvertSdk
  # The in-memory home of the project configuration snapshot and the ONLY
  # surface through which config is read.
  #
  # +DataManager+ owns the project config as a *deep-frozen, string-keyed*
  # snapshot (architecture Decision 5). Config arrives from one of two places —
  # a live fetch (+GET {config_endpoint}/config/{sdkKey}+) or a developer-supplied
  # +data:+ object — and in BOTH cases it is installed identically through
  # {#install_config}: recursively frozen, then atomically swapped behind
  # +@config_mutex+. Because each installed snapshot is a brand-new frozen object
  # graph, decision paths read it LOCK-FREE (no per-read mutex): a reader either
  # sees the whole previous snapshot or the whole new one, never a torn mix.
  # Only install/swap takes the mutex.
  #
  # == No raw config hash crosses the boundary
  #
  # The parsed config envelope is wrapped here and exposed ONLY through
  # hand-written reader methods (+#experiences+, +#feature_by_key(key)+, …) that
  # return frozen sub-hashes / arrays. There is no public accessor for the raw
  # snapshot and no OpenAPI codegen — the reader inventory is derived by hand
  # from the actual config wire shape (the vendored +test-config.json+ fixture).
  #
  # == Wire shape
  #
  # The config envelope is +{"environment" => ..., "data" => {...}}+; the entity
  # collections (+experiences+, +features+, +goals+, +audiences+, +segments+,
  # optional +locations+) plus +account_id+ and the +project+ sub-hash live under
  # +"data"+. +#project_id+ is +data.project.id+. Readers tolerate sparse or
  # absent keys (return +nil+ / +[]+) so a partial config never crashes a reader.
  #
  # == Degrade-gracefully (NFR12)
  #
  # Before any config is installed every reader returns a sentinel (+nil+ for
  # scalars / by-key lookups, +[]+ for collections) and {#config_available?} is
  # +false+. The client constructs successfully even when the first fetch fails;
  # decision methods (Story 2.11) key off these sentinels.
  #
  # == Config caching & TTL bookkeeping (Story 2.7)
  #
  # Every successful install ALSO writes the config through to the injected
  # {DataStoreManager} under +convert_sdk.config.{sdkKey}+ (2.1's single key
  # builder) wrapped as +{"config" => envelope, "fetched_at" => wall_clock}+.
  # The store has no native TTL, so a *wall-clock* +fetched_at+ is stored for
  # cross-process staleness (a Redis-backed cold start can serve a fresh shared
  # entry without fetching). Independently, an in-process *monotonic* timestamp
  # ({#install_config} records it via the injected +clock+) drives the
  # decision-time TTL check ({#ensure_fresh_config!}) so wall-clock jumps can
  # never expire a live snapshot. Monotonic for in-process TTL, wall-clock for
  # the cross-process cache entry — two clocks, two purposes.
  #
  # == Lazy-TTL fallback (timer-off mode)
  #
  # When the background refresh timer is disabled (+data_refresh_interval: nil+),
  # {#ensure_fresh_config!} performs an on-demand staleness check at decision
  # entry points (PHP semantics): a snapshot older than +ttl+ triggers a
  # synchronous refetch (via the injected +refetch+ callable) BEFORE deciding;
  # a failed refetch keeps serving the stale snapshot (the callable warns). The
  # refetch is guarded by a SEPARATE +@fetch_mutex+ (NOT the config mutex), so
  # concurrent stale deciders collapse to ONE fetch (thundering-herd guard) and
  # the HTTP I/O never holds the config mutex.
  class DataManager
    # @param log_manager [LogManager] injected logger for install diagnostics.
    # @param data_store_manager [DataStoreManager, nil] persistence port for the
    #   config cache write; nil disables the write (standalone unit construction).
    # @param config_key [String, nil] the cache key +convert_sdk.config.{sdkKey}+
    #   (built once by {DataStoreManager#config_key}); nil disables the cache.
    # @param ttl [Numeric, nil] the configured +data_refresh_interval+ in seconds.
    #   A non-nil value is timer-ON mode (the background timer keeps config fresh,
    #   so {#ensure_fresh_config!} is a no-op); +nil+ is timer-OFF mode (Lambda /
    #   CLI), which enables the decision-time on-demand refetch and falls the
    #   effective staleness threshold back to {ConvertSdk::DEFAULT_CONFIG_TTL}
    #   (timer-off ≠ TTL-off). The timer-off mode is thus derived from +ttl.nil?+.
    # @param clock [#call] a monotonic time source (seconds, Float) for in-process
    #   TTL math; defaults to +Process.clock_gettime(Process::CLOCK_MONOTONIC)+.
    # @param refetch [#call, nil] a callable performing one full refresh cycle
    #   (HTTP refetch + install + warn-on-failure) for the synchronous timer-off
    #   path; injected by {Client} after construction (it owns the HTTP I/O and
    #   the lifecycle event). Invoked under the thundering-herd fetch mutex.
    def initialize(log_manager:, data_store_manager: nil, config_key: nil, ttl: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, refetch: nil)
      @log_manager = log_manager
      @data_store_manager = data_store_manager
      @config_key = config_key
      @ttl = ttl
      # Timer-off (Lambda/CLI) mode is exactly "no refresh interval configured".
      @timer_off = ttl.nil?
      @clock = clock
      @refetch = refetch
      # The deep-frozen config envelope, or nil before the first install. Read
      # lock-free by every reader; replaced atomically under @config_mutex.
      @config = nil #: Hash[String, untyped]?
      # The monotonic timestamp of the live snapshot's install, or nil pre-config.
      @fetched_at = nil #: Float?
      # Thread safety: guarded by @config_mutex (install/swap + @fetched_at).
      @config_mutex = Thread::Mutex.new
      # Thundering-herd guard for the synchronous timer-off refetch — a SEPARATE
      # mutex so the HTTP refetch never holds the config mutex.
      @fetch_mutex = Thread::Mutex.new
    end

    # The synchronous timer-off refresh callable, injected by {Client} after
    # construction (Client owns the single HTTP port and the lifecycle event).
    # Performs one full refresh cycle (refetch + install + warn-on-failure).
    # @return [#call, nil]
    attr_accessor :refetch

    # Install a parsed config envelope as the live snapshot.
    #
    # The hash is deep-frozen (a fresh recursively-frozen copy — the caller's
    # input is never mutated) and atomically swapped in behind +@config_mutex+.
    # A nil/non-Hash argument is rejected (logged) and leaves the current
    # snapshot intact — install must never crash the host.
    #
    # The first-vs-subsequent determination is made ATOMICALLY inside
    # +@config_mutex+ alongside the swap: the +ready+-once guard (Story 2.5) and
    # the +config.updated+ refresh signal (Story 2.7) both key off the returned
    # marker, so exactly one install in the manager's lifetime is +:first+ even
    # under concurrent installs.
    #
    # @param hash [Hash{String=>Object}] the parsed config envelope
    #   (+{"environment" => ..., "data" => {...}}+).
    # @return [Symbol, false] +:first+ on the first successful install,
    #   +:updated+ on any subsequent install, or +false+ when the argument was
    #   rejected (non-Hash) and no swap happened.
    def install_config(hash)
      unless hash.is_a?(Hash)
        @log_manager.warn("DataManager#install_config: ignored non-Hash config (#{hash.class})")
        return false
      end

      frozen = deep_freeze(hash)
      now = @clock.call
      first = @config_mutex.synchronize do
        was_absent = @config.nil?
        @config = frozen
        @fetched_at = now
        was_absent
      end
      cache_config(frozen)
      @log_manager.info("DataManager#install_config: config installed")
      first ? :first : :updated
    end

    # Install a non-stale cached config entry from the store as the live snapshot
    # — the cross-process warm-start fallback used by {Client} when the initial
    # fetch fails. The entry is +{"config" => envelope, "fetched_at" => wall}+;
    # it is only installed when its WALL-CLOCK age is within +ttl+ (or the
    # default TTL when +ttl+ is nil — timer-off mode). A stale or absent entry
    # is ignored (returns nil). On a successful install an info line records the
    # cache hit.
    #
    # @return [Symbol, nil] the {#install_config} marker on a fresh cache hit,
    #   or nil when no fresh entry was available.
    def install_from_cache_if_fresh
      entry = cached_entry
      return nil unless entry

      fetched_at = entry["fetched_at"]
      config = entry["config"]
      return nil unless fetched_at.is_a?(Numeric) && config.is_a?(Hash)
      return nil if (Time.now.to_f - fetched_at) > effective_ttl

      marker = install_config(config)
      return nil unless marker.is_a?(Symbol)

      @log_manager.info("DataManager#install_from_cache_if_fresh: serving cached config")
      marker
    end

    # Decision-time TTL check for timer-off mode (AC#3, PHP semantics). When a
    # +ttl+ is configured and the live snapshot is older than it (by the
    # monotonic clock), synchronously refetch via the injected callable BEFORE
    # the caller decides. Guarded by the SEPARATE @fetch_mutex so concurrent
    # stale deciders collapse to ONE fetch; the refetch (HTTP I/O) runs OUTSIDE
    # the config mutex. A failed refetch keeps the stale snapshot (the callable
    # warns). A no-op when no ttl/refetch is wired or the snapshot is fresh.
    # @return [void]
    def ensure_fresh_config!
      return unless @timer_off

      refetch = @refetch
      return if refetch.nil?
      return unless config_stale?

      @fetch_mutex.synchronize do
        # Re-check inside the lock: a racing decider may have refreshed already.
        return unless config_stale?

        # The callable performs the full cycle (refetch + install + warn). On
        # success it installs (advancing @fetched_at, so racing deciders that
        # re-check see fresh); on failure it warns and the stale snapshot stays.
        refetch.call
      end
    end

    # @return [Boolean] true when a snapshot exists and its monotonic age exceeds
    #   the configured ttl (or the default ttl when ttl is nil).
    def config_stale?
      fetched_at = @config_mutex.synchronize { @fetched_at }
      return false if fetched_at.nil?

      (@clock.call - fetched_at) > effective_ttl
    end

    # @return [Boolean] true once a config snapshot has been installed.
    def config_available?
      !@config.nil?
    end

    # @return [String, nil] the account id (+data.account_id+), or nil pre-config.
    def account_id
      data&.fetch("account_id", nil)
    end

    # @return [String, nil] the project id (+data.project.id+), or nil pre-config.
    def project_id
      project&.fetch("id", nil)
    end

    # @return [Hash, nil] the frozen +data.project+ sub-hash, or nil pre-config.
    def project
      data&.fetch("project", nil)
    end

    # @return [Array<Hash>] the frozen experiences array ([] pre-config/absent).
    def experiences
      collection("experiences")
    end

    # @return [Array<Hash>] the frozen features array ([] pre-config/absent).
    def features
      collection("features")
    end

    # @return [Array<Hash>] the frozen goals array ([] pre-config/absent).
    def goals
      collection("goals")
    end

    # @return [Array<Hash>] the frozen audiences array ([] pre-config/absent).
    def audiences
      collection("audiences")
    end

    # @return [Array<Hash>] the frozen segments array ([] pre-config/absent).
    def segments
      collection("segments")
    end

    # @return [Array<Hash>] the frozen locations array ([] pre-config/absent).
    #   Absent in some projects (e.g. the vendored fixture) — nil-safe to [].
    def locations
      collection("locations")
    end

    # @param key [String] the experience +key+ to find.
    # @return [Hash, nil] the frozen experience with that key, or nil.
    def experience_by_key(key)
      find_by_key(experiences, key)
    end

    # @param key [String] the feature +key+ to find.
    # @return [Hash, nil] the frozen feature with that key, or nil.
    def feature_by_key(key)
      find_by_key(features, key)
    end

    # @param key [String] the goal +key+ to find.
    # @return [Hash, nil] the frozen goal with that key, or nil.
    def goal_by_key(key)
      find_by_key(goals, key)
    end

    private

    # Write the freshly-installed config through to the store, wrapped with a
    # WALL-CLOCK +fetched_at+ for cross-process staleness. A no-op when no store
    # or key is wired (standalone unit construction). The DataStoreManager
    # contains any store failure (logged), so this never crashes an install.
    def cache_config(frozen)
      store = @data_store_manager
      key = @config_key
      return if store.nil? || key.nil?

      store.set(key, { "config" => frozen, "fetched_at" => Time.now.to_f })
    end

    # Read the raw cache entry from the store, or nil when no store/key is wired
    # or nothing is cached.
    def cached_entry
      store = @data_store_manager
      key = @config_key
      return nil if store.nil? || key.nil?

      entry = store.get(key)
      entry.is_a?(Hash) ? entry : nil
    end

    # The staleness threshold: the configured ttl, or the SDK default (300s) in
    # timer-off mode (ttl nil ≠ TTL-off — Lambda converges on the same cadence).
    def effective_ttl
      @ttl || ConvertSdk::DEFAULT_CONFIG_TTL
    end

    # The frozen +"data"+ sub-hash of the live snapshot, or nil pre-config.
    # Read lock-free: @config is either nil or a fully-frozen graph.
    def data
      @config&.fetch("data", nil)
    end

    # Fetch a frozen collection under +"data"+, defaulting to a frozen empty
    # array when the snapshot or the key is absent.
    def collection(name)
      found = data&.fetch(name, nil)
      found.is_a?(Array) ? found : []
    end

    # Linear scan for the entity whose +"key"+ matches +key+. Entities without a
    # +"key"+ (sparse fixture rows) simply never match. Returns the frozen entity.
    def find_by_key(list, key)
      list.find { |entity| entity.is_a?(Hash) && entity["key"] == key }
    end

    # Build a recursively-frozen copy of +node+. Hashes and arrays are rebuilt
    # with frozen children then frozen; strings are duped-and-frozen; immutable
    # scalars (Integer/Float/Symbol/true/false/nil) pass through unchanged. The
    # caller's original object graph is never mutated.
    def deep_freeze(node)
      case node
      when Hash
        result = {} #: Hash[untyped, untyped]
        node.each { |k, v| result[deep_freeze(k)] = deep_freeze(v) }
        result.freeze
      when Array
        node.map { |element| deep_freeze(element) }.freeze
      when String
        node.frozen? ? node : node.dup.freeze
      else
        node
      end
    end
  end
end
