# frozen_string_literal: true

module ConvertSdk
  # Deterministic visitor bucketing — the cross-SDK variation-assignment engine.
  #
  # Given an experience id, a visitor id, and a caller-built +buckets+ hash
  # (variation id => traffic percentage), this resolves a variation
  # BYTE-IDENTICALLY to the JS SDK +bucketing-manager.ts+ and the proven PHP
  # port +BucketingManager.php+. A visitor MUST bucket into the same variation on
  # web (JS), PHP, and Ruby — the cross-SDK distribution spec is the CI proof.
  #
  # The pipeline mirrors JS exactly, link for link:
  #   1. hash input = +experience_id + String(visitor_id)+  (experience FIRST, no
  #      delimiter) — JS +bucketing-manager.ts:97+, PHP +BucketingManager.php:89+.
  #   2. +hash = MurmurHash3.hash(input, seed)+ — the proven Story 1.2 module;
  #      never reimplemented here.
  #   3. +value = ((hash / 4_294_967_296.0) * max_traffic).to_i+ — float division
  #      then multiply then truncate, operation ORDER preserved. Ruby Float is
  #      IEEE-754 double like JS Number, and +Integer()+-via-+to_i+ truncates
  #      toward zero, matching JS +parseInt(String(val), 10)+ at +bm.ts:99+
  #      (behaviourally floor for all non-negative hash values).
  #   4. +select_bucket+ walks variation cumulative ranges in insertion order:
  #      +prev += pct * 100 + redistribute+; the first variation satisfying the
  #      STRICT upper-bound +value < prev+ wins — JS +bm.ts:60-85+, PHP
  #      +BucketingManager.php:50-72+. No covering range => +nil+ (the caller
  #      treats +nil+ as VARIATION_NOT_DECIDED).
  #
  # Traffic allocation is NOT this class's concern: the caller
  # (ExperienceManager/DataManager) constructs +buckets+ with only the
  # traffic-allocated variations before invoking. BucketingManager is
  # allocation-agnostic and answers one question deterministically: "given this
  # experience config and this visitor id, which variation?"
  #
  # Pure in-memory computation (NFR1) — no I/O, no store access. Bucketing
  # constants (+max_traffic+, +hash_seed+, +max_hash+) come from the injected
  # {Config}, never inline literals. Logging stays at debug for the decisioning
  # internals (FR56); never-crash is the caller's contract, but the class rescues
  # nothing here because its inputs are caller-validated.
  #
  # @api private
  class BucketingManager
    # Build a bucketing engine bound to a {Config}'s frozen bucketing constants.
    #
    # @param config [Config] supplies +max_traffic+, +hash_seed+, +max_hash+.
    # @param log_manager [LogManager, nil] optional debug logger for decisioning
    #   internals; absent in lean unit contexts.
    def initialize(config:, log_manager: nil)
      @max_traffic = config.max_traffic
      @hash_seed = config.hash_seed
      @max_hash = config.max_hash.to_f
      @log_manager = log_manager
    end

    # Compute the deterministic bucket value for a visitor.
    #
    # @param visitor_id [#to_s] the visitor identifier (coerced via +String()+
    #   before hashing, matching JS +String(visitorId)+).
    # @param experience_id [String] the experience identifier; prefixed to the
    #   visitor id to form the hash input. Defaults to +""+.
    # @param seed [Integer] MurmurHash3 seed; defaults to the Config hash seed.
    # @return [Integer] the bucket value in +[0, max_traffic)+.
    def value_visitor_based(visitor_id, experience_id: "", seed: @hash_seed)
      input = "#{experience_id}#{visitor_id}"
      hash = MurmurHash3.hash(input, seed)
      scaled = (hash / @max_hash) * @max_traffic
      result = scaled.to_i

      @log_manager&.debug(
        "BucketingManager#value_visitor_based: " \
        "experience_id=#{experience_id.inspect} visitor_id=#{visitor_id.inspect} " \
        "seed=#{seed} hash=#{hash} scaled=#{scaled} result=#{result}"
      )
      result
    end

    # Select the variation whose cumulative range contains +value+.
    #
    # Walks +buckets+ in insertion order accumulating +pct * 100 + redistribute+
    # per entry, returning the first variation id satisfying the strict
    # upper-bound +value < prev+. Returns +nil+ when no range covers +value+
    # (including an empty +buckets+ hash).
    #
    # @param buckets [Hash{String=>Numeric}] variation id => traffic percentage.
    # @param value [Integer] a bucket value in +[0, max_traffic)+.
    # @param redistribute [Numeric] per-bucket widening offset (default +0+).
    # @return [String, nil] the selected variation id, or +nil+.
    def select_bucket(buckets, value, redistribute = 0)
      variation = nil
      # Float accumulator: JS does `prev += buckets[id]*100 + redistribute` in
      # IEEE-754 double arithmetic (bm.ts:68). Ruby Float is the same double, so
      # accumulating in Float mirrors JS exactly. value (Integer) < prev (Float)
      # compares identically to the JS strict upper-bound check.
      prev = 0.0
      buckets.each do |variation_id, percentage|
        prev += (percentage.to_f * 100) + redistribute
        if value < prev
          variation = variation_id
          break
        end
      end

      @log_manager&.debug(
        "BucketingManager#select_bucket: " \
        "value=#{value} redistribute=#{redistribute} variation=#{variation.inspect}"
      )
      variation
    end

    # Resolve a visitor to a variation, returning the assignment and its bucket
    # value, or +nil+ when no variation range covers the visitor.
    #
    # @param buckets [Hash{String=>Numeric}] variation id => traffic percentage.
    # @param visitor_id [#to_s] the visitor identifier.
    # @param experience_id [String] the experience identifier (default +""+).
    # @param seed [Integer] MurmurHash3 seed (default Config hash seed).
    # @param redistribute [Numeric] per-bucket widening offset (default +0+).
    # @return [Hash{Symbol=>Object}, nil] +{variation_id:, bucketing_allocation:}+
    #   or +nil+ (caller treats +nil+ as VARIATION_NOT_DECIDED).
    def bucket_for_visitor(buckets, visitor_id, experience_id: "", seed: @hash_seed, redistribute: 0)
      value = value_visitor_based(visitor_id, experience_id: experience_id, seed: seed)
      selected = select_bucket(buckets, value, redistribute)

      @log_manager&.debug(
        "BucketingManager#bucket_for_visitor: " \
        "experience_id=#{experience_id.inspect} visitor_id=#{visitor_id.inspect} " \
        "bucket_value=#{value} selected_variation_id=#{selected.inspect}"
      )

      return nil if selected.nil?

      { variation_id: selected, bucketing_allocation: value }
    end
  end
end
