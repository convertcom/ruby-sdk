# frozen_string_literal: true

module ConvertSdk
  # Stores backing the SDK's persistence port (sticky bucketing, goal dedup,
  # config caching). Every store duck-types to +#get(key)+ / +#set(key, value)+
  # — the public extension point validated by {DataStoreManager} at wiring time.
  module Stores
    # The default in-process store: a plain +Hash+ guarded by a +Mutex+.
    #
    # +MemoryStore+ is what {DataStoreManager} falls back to when no custom
    # store is supplied (or a supplied store fails validation). It satisfies the
    # duck-typed store contract — +#get+ / +#set+ — with both operations
    # serialized through a single mutex so concurrent reads and writes from
    # multiple threads cannot corrupt the underlying +Hash+ or lose a write.
    #
    # == Per-process limitation
    #
    # State lives only in this process's memory. It is NOT shared across
    # processes, workers, or machines: sticky bucketing (Story 2.11) and goal
    # deduplication (Story 4.3) that round-trip through a +MemoryStore+ are
    # therefore consistent only within the lifetime of a single process. A
    # forked web worker, a restarted process, or a second host each start with
    # an empty store. For cross-process stickiness and dedup, supply a shared
    # backing store — +RedisStore+ (Story 2.2) is the first-party option.
    #
    # == Thread safety
    #
    # All access to the backing +Hash+ is serialized by +@mutex+; there is no
    # public path to the +Hash+ that bypasses the lock.
    class MemoryStore
      def initialize
        # Thread safety: guarded by @mutex.
        @data = {}
        @mutex = Thread::Mutex.new
      end

      # Read the value stored under +key+.
      #
      # @param key [String] the lookup key.
      # @return [Object, nil] the stored value, or +nil+ if the key is absent.
      def get(key)
        @mutex.synchronize { @data[key] }
      end

      # Store +value+ under +key+, overwriting any existing value.
      #
      # @param key [String] the storage key.
      # @param value [Object] the value to store.
      # @return [Object] the stored value.
      def set(key, value)
        @mutex.synchronize { @data[key] = value }
      end
    end
  end
end
