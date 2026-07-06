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
    # Fixed anchor-scale constant for the ANCHORED bucketing layout (contract
    # v12, qs-01). Unlike +max_traffic+ (config-supplied, used only to scale the
    # visitor's HASH value in {#value_visitor_based}), the anchor/width scale for
    # the anchored range walk is a FIXED module constant in the JS oracle
    # (+bucketing-manager.ts:25+ +DEFAULT_MAX_TRAFFIC = 10000+) — never read from
    # config. Named here (rather than an inline literal in {#select_bucket_anchored})
    # so the constant stays traceable to its JS origin without conflating it with
    # the per-config +@max_traffic+ used elsewhere in this class.
    ANCHORED_MAX_TRAFFIC = 10_000

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

    # Select the variation whose ANCHORED range contains +value+ (contract v12,
    # qs-01/BUCK-2). Given the FULL ordered variation config list (active AND
    # inactive/stopped arms — never pre-filtered), this folds the JS reference's
    # +getBucketRanges+ + +selectBucketAnchored+ (bm.ts:145-190) into one pass so
    # the method stays self-contained and independently unit-testable:
    #
    #   allocation = anchored_allocation(ta) — Float(ta, exception: false) coercion; a
    #     nil coercion result (non-numeric/absent ta) defaults to 100.0, mirroring the
    #     JS oracle's `isNaN(ta) ? 100.0 : Number(ta)`
    #   active     = anchored_active?(status, allocation) — ((status.nil? || status == "")
    #     ? true : status == "running") && allocation.positive?
    #   total_weight = sum(allocation) over ALL entries (active AND inactive)
    #   return nil if total_weight <= 0
    #   cum = 0.0
    #   each entry: anchor = (cum / total_weight) * ANCHORED_MAX_TRAFFIC
    #               width  = active ? allocation * 100 : 0
    #               hit iff anchor <= value < anchor + width (first match wins)
    #               cum += allocation
    #
    # Inactive arms (stopped, or an explicit +traffic_allocation: 0+) keep their
    # weight (anchor stability for the OTHER arms) but get zero width, so they
    # can never themselves be selected. This is a DIFFERENT method from the
    # packed {#select_bucket} — that packed walk is untouched for version<=11.
    #
    # @param variations [Array<Hash>] the FULL ordered variation config list
    #   (+"id"+, +"traffic_allocation"+, +"status"+) — inactive arms included.
    # @param value [Integer] a bucket value in +[0, ANCHORED_MAX_TRAFFIC)+.
    # @return [String, nil] the selected variation id, or +nil+ (including when
    #   +total_weight <= 0+ or the list is empty).
    def select_bucket_anchored(variations, value)
      entries = anchored_allocations(variations)
      total_weight = entries.sum { |entry| entry[:allocation] }
      variation = total_weight.positive? ? anchored_walk(entries, total_weight, value) : nil

      @log_manager&.debug(
        "BucketingManager#select_bucket_anchored: " \
        "value=#{value} total_weight=#{total_weight} variation=#{variation.inspect}"
      )
      variation
    end

    # Resolve a visitor to a variation under the ANCHORED layout (contract v12),
    # returning the SAME shape as {#bucket_for_visitor} (AC9 — no return-shape
    # drift): +{variation_id:, bucketing_allocation:}+ or +nil+. Reuses the
    # existing visitor-hash value unchanged (JS +getBucketForVisitorAnchored+,
    # bm.ts:195-215) then resolves it through {#select_bucket_anchored}.
    #
    # @param variations [Array<Hash>] the FULL ordered variation config list
    #   (active AND inactive arms) — see {#select_bucket_anchored}.
    # @param visitor_id [#to_s] the visitor identifier.
    # @param experience_id [String] the experience identifier (default +""+).
    # @param seed [Integer] MurmurHash3 seed (default Config hash seed).
    # @return [Hash{Symbol=>Object}, nil] +{variation_id:, bucketing_allocation:}+
    #   or +nil+ (caller treats +nil+ as VARIATION_NOT_DECIDED).
    def bucket_for_visitor_anchored(variations, visitor_id, experience_id: "", seed: @hash_seed)
      value = value_visitor_based(visitor_id, experience_id: experience_id, seed: seed)
      selected = select_bucket_anchored(variations, value)

      @log_manager&.debug(
        "BucketingManager#bucket_for_visitor_anchored: " \
        "experience_id=#{experience_id.inspect} visitor_id=#{visitor_id.inspect} " \
        "bucket_value=#{value} selected_variation_id=#{selected.inspect}"
      )

      return nil if selected.nil?

      { variation_id: selected, bucketing_allocation: value }
    end

    private

    # Build +{id:, allocation:, active:}+ entries from the raw ordered variation
    # config list, mirroring the JS +_buildVariationAllocations+ mapping
    # (data-manager.ts:591-610). Entries without an +"id"+ are skipped entirely
    # (never counted in +total_weight+, never selectable) — defensive against a
    # sparse/malformed config row, same tolerance the rest of the SDK applies.
    def anchored_allocations(variations)
      variations.each_with_object([]) do |variation, entries|
        next unless variation.is_a?(Hash) && variation["id"]

        allocation = anchored_allocation(variation["traffic_allocation"])
        active = anchored_active?(variation["status"], allocation)
        entries << { id: variation["id"], allocation: allocation, active: active }
      end
    end

    # Mirrors the JS +isNaN(ta) ? 100.0 : Number(ta)+ mapping
    # (data-manager.ts:594-601) via +Float(x, exception: false)+ coercion: a
    # numeric-looking String (e.g. +"50"+) coerces to its numeric weight
    # exactly like the JS oracle's +Number()+, not just a genuine
    # Integer/Float. A genuinely non-numeric value, +nil+, or an absent field
    # coerces to +nil+ and defaults to +100.0+ (full-allocation weight, AC5) —
    # RBS core types +Float(untyped, exception: false)+ as +Float?+, so the
    # nil-check both implements the JS default and narrows the return to the
    # declared +-> Float+.
    #
    # Hard boundary (documented, not fixable in Ruby): +JSON.parse+ collapses
    # an explicit JSON +null+ +traffic_allocation+ and an ABSENT field to the
    # same Ruby +nil+, so this SDK cannot reproduce JS's split (JS: absent ->
    # +undefined+ -> +isNaN+ -> 100.0/active; explicit +null+ ->
    # +Number(null)+ is +0+ -> 0/inactive). We match JS for the served/tested
    # case (absent -> 100.0/active); explicit-null +traffic_allocation+ is
    # never served (0 occurrences in the 59-vector golden fixture). The same
    # coercion-class divergence applies to an empty-string/whitespace-only
    # +traffic_allocation+: +Float("", exception: false)+ (and whitespace-only
    # strings) coerce to +nil+ -> defaults to 100.0/active here, whereas JS's
    # +Number("")+ is +0+ -> 0/inactive; behaviorally neutral for the actual
    # contract since +traffic_allocation+ is a backend-served numeric field
    # and this value is never served (0 occurrences of empty-string/
    # whitespace-only +ta+ in the 59-vector golden cross-SDK fixture).
    def anchored_allocation(traffic_allocation)
      coerced = Float(traffic_allocation, exception: false)
      coerced.nil? ? 100.0 : coerced
    end

    # +true+ when the variation is eligible for a non-zero anchored width: a
    # +nil+/+""+ status defaults to running (JS +status ? status === RUNNING :
    # true+, treating an empty string as falsy), AND the allocation is positive
    # (an explicit +traffic_allocation: 0+ is inactive, never defaulted to 100).
    def anchored_active?(status, allocation)
      status_active = status.nil? || status == "" ? true : status == "running"
      status_active && allocation.positive?
    end

    # Walk the anchored +entries+ in config order, returning the first entry
    # whose half-open +[anchor, anchor + width)+ band contains +value+, or +nil+
    # when no band covers it. +total_weight+ is guaranteed positive by the caller.
    def anchored_walk(entries, total_weight, value)
      cum = 0.0
      entries.each do |entry|
        anchor = (cum / total_weight) * ANCHORED_MAX_TRAFFIC
        width = entry[:active] ? entry[:allocation] * 100 : 0
        return entry[:id] if value >= anchor && value < anchor + width

        cum += entry[:allocation]
      end
      nil
    end
  end
end
