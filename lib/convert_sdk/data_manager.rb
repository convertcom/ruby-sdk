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
  # == Config caching
  #
  # Install here is in-memory only. Writing the snapshot through to the
  # {DataStoreManager} cache (with TTL) and the lazy refresh path are Story 2.7's
  # concern; this story holds the in-memory snapshot and the +ready+-once trigger.
  class DataManager
    # @param log_manager [LogManager] injected logger for install diagnostics.
    def initialize(log_manager:)
      @log_manager = log_manager
      # The deep-frozen config envelope, or nil before the first install. Read
      # lock-free by every reader; replaced atomically under @config_mutex.
      @config = nil #: Hash[String, untyped]?
      # Thread safety: guarded by @config_mutex (install/swap only).
      @config_mutex = Thread::Mutex.new
    end

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
      first = @config_mutex.synchronize do
        was_absent = @config.nil?
        @config = frozen
        was_absent
      end
      @log_manager.info("DataManager#install_config: config installed")
      first ? :first : :updated
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
