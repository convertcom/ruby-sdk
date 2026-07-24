# frozen_string_literal: true

require "spec_helper"

# Unit spec for the deterministic bucketing engine.
#
# BucketingManager is a pure-math unit (NFR1): given an experience id, a visitor
# id, and a caller-built +buckets+ hash (variation id => traffic percentage), it
# resolves a variation byte-identically to the JS SDK +bucketing-manager.ts+ and
# the proven PHP port. This spec is the 95% line+branch coverage proof; the
# cross-SDK distribution proof lives in +spec/cross_sdk/bucketing_distribution_spec.rb+.
#
# All numeric expectations are DERIVED from the verified formula against the
# proven +ConvertSdk::MurmurHash3.hash+ (Story 1.2) — never invented goldens.
#   hash    = MurmurHash3.hash(experience_id + visitor_id, seed)
#   value   = ((hash / 4_294_967_296.0) * max_traffic).to_i   # floor for non-neg, == JS parseInt @ bm.ts:99
#   variant = first id whose cumulative (pct*100 + redistribute) range satisfies value < prev
RSpec.describe ConvertSdk::BucketingManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) do
    ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
  end
  # A standalone Config exposing the frozen bucketing constants (seed 9999,
  # max_traffic 10000, max_hash 2^32) — the manager reads these, never literals.
  let(:config) { ConvertSdk::Config.new(data: {}) }
  let(:manager) { described_class.new(config: config, log_manager: log_manager) }

  # Re-derive the expected bucket value straight from the proven hash so the
  # spec stays a formula proof, not a table of magic numbers.
  def expected_value(experience_id, visitor_id, seed: 9999, max_traffic: 10_000)
    hash = ConvertSdk::MurmurHash3.hash("#{experience_id}#{visitor_id}", seed)
    ((hash / 4_294_967_296.0) * max_traffic).to_i
  end

  # Anchored-layout variation-config builder: {id, traffic_allocation, status}.
  # Mirrors the golden-vector fixture's variation shape (spec/fixtures/cross_sdk/
  # cross-sdk-bucketing-vectors.json — qs-01 anchored bucketing layout) so
  # hand-built scenarios below stay structurally identical to the vendored
  # vectors. Omitting +ta+ (the default +:absent+ sentinel) mirrors an absent
  # +traffic_allocation+ field on the wire (NaN/absent -> 100.0 default, AC5).
  def variation(variation_id, allocation = :absent, status: nil)
    v = { "id" => variation_id }
    v["traffic_allocation"] = allocation unless allocation == :absent
    v["status"] = status if status
    v
  end

  describe "#value_visitor_based" do
    # Tabular vector cases: each pair is bucketed via the public method and
    # checked against the independently-derived formula value.
    [
      %w[100218245 visitor-1],
      %w[100218245 visitor-2],
      ["100218245", "visitor-456"],
      ["", "testString"], # the cross-SDK anchor input (hash 2241850228)
      %w[exp-1 abc]
    ].each do |experience_id, visitor_id|
      it "matches the derived formula for experience=#{experience_id.inspect} visitor=#{visitor_id.inspect}" do
        expect(manager.value_visitor_based(visitor_id, experience_id: experience_id))
          .to eq(expected_value(experience_id, visitor_id))
      end
    end

    it "concatenates experience_id BEFORE visitor_id (operand order is load-bearing)" do
      # "ab"+"c" and "a"+"bc" hash the same input string only if order were ignored;
      # the manager must hash exactly experience_id + visitor_id.
      same = manager.value_visitor_based("c", experience_id: "ab")
      expect(same).to eq(expected_value("ab", "c"))
      unless expected_value("ab", "c") == expected_value("c", "ab")
        expect(manager.value_visitor_based("c", experience_id: "ab"))
          .not_to eq(manager.value_visitor_based("ab", experience_id: "c"))
      end
    end

    it "defaults experience_id to empty string when omitted" do
      expect(manager.value_visitor_based("testString")).to eq(expected_value("", "testString"))
    end

    it "honours an explicit seed override" do
      expect(manager.value_visitor_based("v", experience_id: "e", seed: 42))
        .to eq(expected_value("e", "v", seed: 42))
    end

    it "coerces a non-string visitor id via String() before hashing" do
      expect(manager.value_visitor_based(12_345, experience_id: "e"))
        .to eq(expected_value("e", "12345"))
    end

    it "produces an integer in [0, max_traffic)" do
      value = manager.value_visitor_based("any-visitor", experience_id: "any-exp")
      expect(value).to be_a(Integer)
      expect(value).to be_between(0, 9999).inclusive
    end

    it "emits a debug log line tagged BucketingManager#value_visitor_based" do
      manager.value_visitor_based("v", experience_id: "e")
      expect(sink.messages.join("\n")).to include("BucketingManager#value_visitor_based")
    end
  end

  describe "#select_bucket" do
    # buckets map variation id => traffic percentage; cumulative range in bucket
    # space is pct*100 (50% -> 5000). Strict upper-bound: variation chosen when
    # value < cumulative_prev.
    let(:buckets) { { "var-a" => 50, "var-b" => 50 } } # 0..4999 -> a, 5000..9999 -> b

    it "selects the first variation when value falls in its range" do
      expect(manager.select_bucket(buckets, 0)).to eq("var-a")
      expect(manager.select_bucket(buckets, 4999)).to eq("var-a")
    end

    it "selects the second variation at the strict boundary (value == first cumulative)" do
      # 5000 is NOT < 5000, so it rolls into var-b — strict upper-bound semantics.
      expect(manager.select_bucket(buckets, 5000)).to eq("var-b")
      expect(manager.select_bucket(buckets, 9999)).to eq("var-b")
    end

    it "returns nil when no cumulative range covers the value" do
      # total coverage is 10000; a value at/above the total has no range.
      expect(manager.select_bucket(buckets, 10_000)).to be_nil
    end

    it "returns nil for an empty buckets hash" do
      expect(manager.select_bucket({}, 0)).to be_nil
    end

    it "skips a zero-traffic variation entirely" do
      # var-a has 0% -> its cumulative range is empty; everything below 10000 -> var-b.
      zero = { "var-a" => 0, "var-b" => 100 }
      expect(manager.select_bucket(zero, 0)).to eq("var-b")
      expect(manager.select_bucket(zero, 9999)).to eq("var-b")
    end

    it "handles a 100/0 split (first variation owns the whole space)" do
      split = { "var-a" => 100, "var-b" => 0 }
      expect(manager.select_bucket(split, 0)).to eq("var-a")
      expect(manager.select_bucket(split, 9999)).to eq("var-a")
    end

    it "walks variations in insertion order" do
      three = { "a" => 33, "b" => 33, "c" => 34 } # 0..3299 a, 3300..6599 b, 6600..9999 c
      expect(manager.select_bucket(three, 3299)).to eq("a")
      expect(manager.select_bucket(three, 3300)).to eq("b")
      expect(manager.select_bucket(three, 6599)).to eq("b")
      expect(manager.select_bucket(three, 6600)).to eq("c")
    end

    it "applies the redistribute offset to each cumulative step" do
      # redistribute widens each range by the offset: prev += pct*100 + redistribute.
      # {a:50} with redistribute 100 -> a covers 0..5099.
      expect(manager.select_bucket({ "a" => 50 }, 5099, 100)).to eq("a")
      expect(manager.select_bucket({ "a" => 50 }, 5100, 100)).to be_nil
    end

    it "emits a debug log line tagged BucketingManager#select_bucket" do
      manager.select_bucket(buckets, 0)
      expect(sink.messages.join("\n")).to include("BucketingManager#select_bucket")
    end
  end

  describe "#bucket_for_visitor" do
    let(:buckets) { { "100299456" => 50, "100299457" => 50 } }

    it "returns variation_id and bucketing_allocation for a covered visitor" do
      value = manager.value_visitor_based("visitor-456", experience_id: "100234567")
      result = manager.bucket_for_visitor(buckets, "visitor-456", experience_id: "100234567")
      expect(result).to be_a(Hash)
      expect(result[:bucketing_allocation]).to eq(value)
      expect(buckets.keys).to include(result[:variation_id])
    end

    it "returns nil when no variation range covers the visitor's bucket value" do
      # Buckets covering only the bottom 10% leave most visitors uncovered.
      narrow = { "only" => 0 } # covers nothing
      expect(manager.bucket_for_visitor(narrow, "visitor-456", experience_id: "100234567")).to be_nil
    end

    it "is deterministic across instances for the same inputs" do
      other = described_class.new(config: config, log_manager: log_manager)
      100.times do |i|
        vid = "visitor-#{i}"
        expect(manager.bucket_for_visitor(buckets, vid, experience_id: "exp-1"))
          .to eq(other.bucket_for_visitor(buckets, vid, experience_id: "exp-1"))
      end
    end

    it "passes the redistribute option through to select_bucket" do
      # With redistribute 5000, even a {a:0} bucket covers 0..4999.
      result = manager.bucket_for_visitor({ "a" => 0 }, "visitor-1",
                                          experience_id: "e", redistribute: 5000)
      value = manager.value_visitor_based("visitor-1", experience_id: "e")
      if value < 5000
        expect(result[:variation_id]).to eq("a")
      else
        expect(result).to be_nil
      end
    end
  end

  describe "construction" do
    it "reads bucketing constants from the injected Config (no inline literals)" do
      # A Config with a custom max_traffic must change the scaling.
      custom = ConvertSdk::Config.new(data: {}, max_traffic: 1000)
      mgr = described_class.new(config: custom, log_manager: log_manager)
      expect(mgr.value_visitor_based("v", experience_id: "e"))
        .to eq(expected_value("e", "v", max_traffic: 1000))
    end

    context "without a log manager (lean path — no debug emission)" do
      let(:lean) { described_class.new(config: config) }

      it "constructs without raising" do
        expect { described_class.new(config: config) }.not_to raise_error
      end

      # Each public method must take its no-logger (&. else) branch and still
      # return the same result as the logged manager — this covers the lean
      # debug-skip branch in all three methods toward the 95% branch gate.
      it "computes value_visitor_based identically with no logger" do
        expect(lean.value_visitor_based("v", experience_id: "e"))
          .to eq(manager.value_visitor_based("v", experience_id: "e"))
      end

      it "selects a bucket identically with no logger" do
        expect(lean.select_bucket({ "a" => 50, "b" => 50 }, 0)).to eq("a")
      end

      it "buckets a visitor identically with no logger" do
        buckets = { "a" => 50, "b" => 50 }
        expect(lean.bucket_for_visitor(buckets, "visitor-7", experience_id: "exp-1"))
          .to eq(manager.bucket_for_visitor(buckets, "visitor-7", experience_id: "exp-1"))
      end
    end
  end

  # Anchored bucketing layout (qs-01, bucketing contract v12 — RED phase).
  #
  # #select_bucket_anchored is the anchored-layout counterpart of #select_bucket:
  # given the FULL ordered variation list (active AND inactive/stopped arms) and
  # an already-computed bucket +value+, it resolves the covering variation or
  # +nil+. It is a NEW method — the packed #select_bucket is untouched and stays
  # the version<=11 walk.
  #
  # Per the spec (qs-01 "The contract"), mirroring the JS oracle's
  # isNaN(ta) ? 100.0 : Number(ta) coercion (numeric STRINGS coerce, not just
  # Integer/Float):
  #   allocation = Float(ta, exception: false) || 100.0
  #   active     = (status.nil? ? true : status == "running") && (allocation > 0)
  #   total_weight = sum(allocation) over ALL entries (active AND inactive)
  #   return nil if total_weight <= 0
  #   cum = 0.0
  #   each entry: anchor = (cum / total_weight) * 10000
  #               width  = active ? allocation * 100 : 0
  #               hit iff anchor <= value < anchor + width
  #               cum += allocation
  #   no hit -> nil
  #
  # None of these examples invent magic numbers: every scenario either derives
  # the anchor/width from the formula above by hand (boundaries kept small and
  # exact — single/double-arm cases) or is copied verbatim from a golden vector
  # in cross-sdk-bucketing-vectors.json (stopped-arm-stability, ta-zero-width).
  describe "#select_bucket_anchored" do
    describe "AC5 — boundaries: value == anchor is IN, value == anchor + width is OUT" do
      # Single arm at 50%: anchor 0, width 5000 -> band [0, 5000).
      let(:single_arm) { [variation("O", 50, status: "running")] }

      { 0 => "O", 4_999 => "O", 5_000 => nil }.each do |value, expected|
        it "value=#{value} -> #{expected.inspect}" do
          expect(manager.select_bucket_anchored(single_arm, value)).to eq(expected)
        end
      end
    end

    describe "boundary on a NON-FIRST anchor (cumulative weight > 0)" do
      # Two equal arms: O anchor 0 width 5000; V1 anchor 5000 width 5000.
      let(:two_arms) { [variation("O", 50, status: "running"), variation("V1", 50, status: "running")] }

      { 4_999 => "O", 5_000 => "V1", 9_999 => "V1" }.each do |value, expected|
        it "value=#{value} -> #{expected}" do
          expect(manager.select_bucket_anchored(two_arms, value)).to eq(expected)
        end
      end
    end

    describe "AC5 — NaN/absent traffic_allocation defaults to 100.0 weight" do
      # B (ta=5, weight 5) is listed FIRST so its fixed [0,500) band is checked
      # before A (ta absent). total_weight = 5 + 100 = 105, so A's anchor sits
      # at (5/105)*10000 ~= 476.19 with a width of 100*100 = 10000 -- if the
      # spec's "absent -> 100.0" default were wrong (e.g. treated as 0), A would
      # never be reachable at all.
      let(:variations) { [variation("B", 5, status: "running"), variation("A")] }

      it "keeps B's own fixed band ahead of A (first-match-in-order)" do
        expect(manager.select_bucket_anchored(variations, 0)).to eq("B")
        expect(manager.select_bucket_anchored(variations, 499)).to eq("B")
      end

      it "admits A once B's fixed band ends, proving A's weight defaulted to 100 (not 0)" do
        expect(manager.select_bucket_anchored(variations, 500)).to eq("A")
        expect(manager.select_bucket_anchored(variations, 9_999)).to eq("A")
      end
    end

    describe "AC5 — total_weight <= 0 is never bucketed" do
      let(:all_zero) { [variation("O", 0, status: "running"), variation("V1", 0, status: "stopped")] }

      it "returns nil for any value when every entry has zero (or negative) weight" do
        [0, 1, 5_000, 9_999].each do |value|
          expect(manager.select_bucket_anchored(all_zero, value)).to be_nil
        end
      end
    end

    describe "AC4 — a stopped arm keeps its weight but gets zero width; other anchors are untouched" do
      # O=10/V1=80(stopped)/V2=10 -- the EXACT config from the golden
      # stopped-arm-stability vectors (experience 900000001). O:[0,1000)
      # V1: anchor 1000, width 0 (dead point) V2:[9000,10000).
      let(:variations) do
        [variation("O", 10, status: "running"), variation("V1", 80, status: "stopped"),
         variation("V2", 10, status: "running")]
      end

      { 999 => "O", 1_000 => nil, 8_999 => nil, 9_000 => "V2", 9_999 => "V2" }.each do |value, expected|
        it "value=#{value} -> #{expected.inspect}" do
          expect(manager.select_bucket_anchored(variations, value)).to eq(expected)
        end
      end
    end

    describe "AC4/AC5 — an EXPLICIT traffic_allocation: 0 is zero width, never defaulted to 100" do
      # O=2/V1=47/Z=0(explicit)/V2=1 -- the EXACT config from the golden
      # ta-zero-width vectors. Z's weight is 0 (never 100), so it never perturbs
      # V1's or V2's anchors and can never itself be selected. cum after O+V1 is
      # 49, so BOTH Z and V2 anchor at (49/50)*10000 = 9800; V2's width is
      # 1*100 = 100, giving it a tight [9800, 9900) band immediately after V1.
      let(:variations) do
        [variation("O", 2, status: "running"), variation("V1", 47, status: "running"),
         variation("Z", 0, status: "running"), variation("V2", 1, status: "running")]
      end

      it "never selects Z regardless of value" do
        (0..9_999).step(1_111).each do |value|
          expect(manager.select_bucket_anchored(variations, value)).not_to eq("Z")
        end
      end

      it "gives V2 a tight [9800, 9900) band immediately after V1 (Z contributed zero weight)" do
        expect(manager.select_bucket_anchored(variations, 9_800)).to eq("V2")
        expect(manager.select_bucket_anchored(variations, 9_899)).to eq("V2")
        expect(manager.select_bucket_anchored(variations, 9_900)).not_to eq("V2")
      end
    end

    it "returns nil for an empty variation list" do
      expect(manager.select_bucket_anchored([], 0)).to be_nil
    end

    # Cross-SDK parity: total_weight MUST be a NAIVE left-to-right fold (JS
    # bucketing-manager.ts:153-156, `allocations.reduce((sum, {allocation}) =>
    # sum + allocation, 0)`), never Ruby's Array#sum (a Kahan-Babuska
    # compensated algorithm for Float arrays). This 3-way ~thirds split is a
    # VERIFIED divergence (not invented): [33.34, 33.330000000000005, 33.33].sum
    # == 100.0 while the same array folded naively == 100.00000000000001 (1
    # ULP apart) -- and that 1-ULP total_weight difference flips the walk's
    # outcome at value=6667 from "V1" (compensated) to not-bucketed (naive,
    # matching JS). Neighboring values 6666/6668 are UNCHANGED, isolating the
    # divergence to the exact anchor boundary.
    describe "JS parity — total_weight is a naive fold, not a compensated sum" do
      let(:thirds_split) do
        [
          variation("O", 33.34, status: "running"),
          variation("V1", 33.330000000000005, status: "running"),
          variation("V2", 33.33, status: "running")
        ]
      end

      it "matches JS's naive-fold total_weight at the exact boundary value (not-bucketed, not V1)" do
        expect(manager.select_bucket_anchored(thirds_split, 6_667)).to be_nil
      end

      it "leaves the neighboring values unaffected (the divergence is boundary-exact)" do
        expect(manager.select_bucket_anchored(thirds_split, 6_666)).to eq("V1")
        expect(manager.select_bucket_anchored(thirds_split, 6_668)).to eq("V2")
      end
    end
  end

  # #bucket_for_visitor_anchored composes #value_visitor_based +
  # #select_bucket_anchored, mirroring #bucket_for_visitor's shape exactly
  # (AC9 — no return-shape drift): {variation_id:, bucketing_allocation:} or nil.
  describe "#bucket_for_visitor_anchored" do
    # O=10/V1=80(stopped)/V2=10 -- the EXACT config + visitor ids from the golden
    # stopped-arm-stability vectors (experience 900000001), so the expectations
    # below are read off the vendored fixture, never invented.
    let(:variations) do
      [variation("O", 10, status: "running"), variation("V1", 80, status: "stopped"),
       variation("V2", 10, status: "running")]
    end
    let(:experience_id) { "900000001" }

    it "returns the same {variation_id:, bucketing_allocation:} shape as #bucket_for_visitor (AC9)" do
      result = manager.bucket_for_visitor_anchored(variations, "anchor-gate-visitor-106", experience_id: experience_id)
      expect(result.keys).to contain_exactly(:variation_id, :bucketing_allocation)
    end

    it "matches the golden vector for this exact config (anchor-gate-visitor-106 -> O)" do
      result = manager.bucket_for_visitor_anchored(variations, "anchor-gate-visitor-106", experience_id: experience_id)
      expect(result[:variation_id]).to eq("O")
    end

    it "matches the golden vector for this exact config (anchor-gate-visitor-162 -> V2, unaffected by V1's stop)" do
      result = manager.bucket_for_visitor_anchored(variations, "anchor-gate-visitor-162", experience_id: experience_id)
      expect(result[:variation_id]).to eq("V2")
    end

    it "carries the SAME bucket value #value_visitor_based would compute (no hashing drift)" do
      value = manager.value_visitor_based("anchor-gate-visitor-106", experience_id: experience_id)
      result = manager.bucket_for_visitor_anchored(variations, "anchor-gate-visitor-106", experience_id: experience_id)
      expect(result[:bucketing_allocation]).to eq(value)
    end

    it "returns nil when no band covers the visitor's value" do
      empty = [variation("O", 0, status: "running")]
      expect(manager.bucket_for_visitor_anchored(empty, "anyone", experience_id: "exp")).to be_nil
    end

    it "is deterministic across instances for the same inputs" do
      other = described_class.new(config: config, log_manager: log_manager)
      5.times do |i|
        vid = "visitor-#{i}"
        expect(manager.bucket_for_visitor_anchored(variations, vid, experience_id: experience_id))
          .to eq(other.bucket_for_visitor_anchored(variations, vid, experience_id: experience_id))
      end
    end
  end
end
