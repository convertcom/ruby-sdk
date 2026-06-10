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
end
