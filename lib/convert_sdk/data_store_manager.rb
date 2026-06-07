# frozen_string_literal: true

module ConvertSdk
  # The single persistence port every manager flows through.
  #
  # +DataStoreManager+ wraps a duck-typed *store* (anything responding to
  # +#get(key)+ / +#set(key, value)+) and is the ONLY object that holds a raw
  # store reference — managers (config caching in Story 2.7, sticky bucketing in
  # 2.11, goal dedup in 4.3) never touch a store directly. This gives the SDK
  # one place to enforce three guarantees:
  #
  # 1. *Validation at wiring time.* The supplied store is duck-type-checked once,
  #    at construction. A non-conforming store is rejected with a logged error
  #    and replaced by a {Stores::MemoryStore} — wiring NEVER raises and NEVER
  #    accepts a broken store. (The JS SDK's +isValidDataStore+ checks only that
  #    +get+/+set+ are functions, with no arity enforcement; this port matches
  #    that contract exactly. Unlike JS — which leaves its data store undefined
  #    on invalid input — this Ruby port intentionally falls back to a working
  #    MemoryStore, because a Ruby process must never crash on SDK wiring errors.)
  #
  # 2. *Never-crash passthrough.* {#get} / {#set} rescue +StandardError+ from a
  #    user-supplied store and log it; a raising store degrades to +nil+ (get) or
  #    a no-op (set) instead of crashing the host.
  #
  # 3. *Atomic visitor-data merge.* {#merge_visitor_data} runs the whole
  #    read-modify-write cycle inside a manager-level mutex, so a compound
  #    "read current state, decide, write" operation is atomic by construction.
  #    Goal dedup (Story 4.3) builds its check-then-mark on this guarantee.
  #
  # == One store, two tenants
  #
  # A single store instance backs both config caching and visitor data. Keys are
  # namespaced so the two never collide: config entries use
  # +convert_sdk.config.{sdk_key}+ ({#config_key}) and visitor entries use
  # +{account_id}-{project_id}-{visitor_id}+ ({#visitor_key}, byte-identical to
  # the JS +getStoreKey+ format). The two key shapes are structurally disjoint.
  #
  # == StoreData
  #
  # Visitor data is a string-keyed hash of the JS +StoreData+ shape —
  # +{"bucketing" => {...}, "segments" => {...}, "goals" => {...}}+ (plus
  # +"locations"+). Everything stored is string-keyed (wire-world); no symbols
  # appear in stored structures.
  #
  # == Thread safety
  #
  # The merge cycle is guarded by +@merge_mutex+. The default {Stores::MemoryStore}
  # adds its own internal lock, so in-process merges are atomic. For external
  # stores (e.g. +RedisStore+, Story 2.2) the same code path runs, but
  # cross-process merge atomicity is store-dependent and must be provided by the
  # backing store.
  class DataStoreManager
    # Methods a store must respond to (JS +isValidDataStore+ contract — presence
    # only, no arity check).
    REQUIRED_STORE_METHODS = %i[get set].freeze

    # @return [Object] the validated backing store (the supplied store, or a
    #   {Stores::MemoryStore} fallback).
    attr_reader :store

    # @param store [Object, nil] a duck-typed store responding to +get+/+set+.
    #   +nil+ or an invalid store falls back to a new {Stores::MemoryStore}.
    # @param log_manager [LogManager] injected logger for validation/passthrough
    #   diagnostics.
    def initialize(log_manager:, store: nil)
      @log_manager = log_manager
      @store = resolve_store(store)
      # Thread safety: guarded by @merge_mutex.
      @merge_mutex = Thread::Mutex.new
    end

    # Read the value stored under +key+. A raising store is contained: the error
    # is logged and +nil+ is returned.
    #
    # @param key [String]
    # @return [Object, nil]
    def get(key)
      @store.get(key)
    rescue StandardError => e
      @log_manager.error("DataStoreManager#get: store raised (#{e.message})")
      nil
    end

    # Store +value+ under +key+. A raising store is contained: the error is
    # logged and the call is a no-op.
    #
    # @param key [String]
    # @param value [Object]
    # @return [void]
    def set(key, value)
      @store.set(key, value)
      nil
    rescue StandardError => e
      @log_manager.error("DataStoreManager#set: store raised (#{e.message})")
      nil
    end

    # Build the visitor-data store key — byte-identical to the JS
    # +getStoreKey+ format +`${accountId}-${projectId}-${visitorId}`+. This is
    # the SINGLE construction site for visitor keys.
    #
    # @param account_id [String]
    # @param project_id [String]
    # @param visitor_id [String]
    # @return [String]
    def visitor_key(account_id, project_id, visitor_id)
      "#{account_id}-#{project_id}-#{visitor_id}"
    end

    # Build the config-cache store key. SINGLE construction site for config keys.
    #
    # @param sdk_key [String]
    # @return [String]
    def config_key(sdk_key)
      "convert_sdk.config.#{sdk_key}"
    end

    # Atomically read-modify-write a visitor's +StoreData+.
    #
    # The entire cycle — read current data, yield it to the block, deep-merge
    # the block's returned partial, write the result — runs inside
    # +@merge_mutex+, so it is atomic by construction. The block receives the
    # current stored data (or +{}+ for a first write) and returns a +StoreData+
    # partial to merge in; this lets a caller inspect current state and decide
    # what to write atomically (the substrate for Story 4.3's check-then-mark
    # goal dedup).
    #
    # Merge semantics match the JS +objectDeepMerge+: nested string-keyed hashes
    # merge recursively, arrays union (deduped, new values first), and scalars
    # from the partial win.
    #
    # @param account_id [String]
    # @param project_id [String]
    # @param visitor_id [String]
    # @yieldparam current [Hash] the current stored +StoreData+ (or +{}+).
    # @yieldreturn [Hash] the +StoreData+ partial to merge in.
    # @return [Hash] the merged, persisted +StoreData+.
    def merge_visitor_data(account_id, project_id, visitor_id)
      key = visitor_key(account_id, project_id, visitor_id)
      @merge_mutex.synchronize do
        current = get(key) || {}
        partial = yield(current)
        merged = deep_merge(current, partial || {})
        set(key, merged)
        merged
      end
    end

    private

    # Validate and resolve the backing store. Invalid → logged error + a fresh
    # MemoryStore fallback.
    def resolve_store(store)
      return Stores::MemoryStore.new if store.nil?

      if valid_store?(store)
        store
      else
        @log_manager.error("DataStoreManager#resolve_store: rejected store " \
                           "#{store.class} (must respond to get/set); using MemoryStore")
        Stores::MemoryStore.new
      end
    end

    # JS +isValidDataStore+ parity: presence of +get+ and +set+, no arity check.
    def valid_store?(store)
      REQUIRED_STORE_METHODS.all? { |m| store.respond_to?(m) }
    end

    # Recursive deep merge mirroring the JS +objectDeepMerge+ contract. Arrays
    # union (new values first, deduped); nested hashes recurse; scalars from the
    # right-hand (new) value win.
    def deep_merge(base, incoming)
      base.merge(incoming) do |_key, base_val, new_val|
        if base_val.is_a?(Array) && new_val.is_a?(Array)
          (new_val + base_val).uniq
        elsif base_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(base_val, new_val)
        else
          new_val
        end
      end
    end
  end
end
