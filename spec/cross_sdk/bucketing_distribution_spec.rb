# frozen_string_literal: true

require "spec_helper"
require "json"

# Cross-SDK bucketing distribution & pipeline parity suite.
#
# This is the release-blocking proof that Ruby buckets visitors byte-identically
# to every other Convert SDK (JS reference + proven PHP port). It runs inside the
# independent parity CI job (everything under spec/cross_sdk; wired in Story 1.2).
#
# Two complementary proofs, both data-driven (no copy-paste assertion blocks):
#
#   1. PIPELINE PARITY — mirrors php-sdk
#      tests/CrossSdk/BucketingConsistencyTest.php::bucketingPipelineProvider:
#      for every seed-9999 vector in the vendored test-vectors.json, the
#      normalized bucket value MUST equal intval((expected_hash / 2^32) * 10000).
#      The Ruby pipeline (MurmurHash3 -> float scale -> truncate) is checked
#      against that independently-computed expectation. The "testString" @ 9999
#      anchor (hash 2241850228) is exercised as one of those vectors.
#
#   2. DISTRIBUTION — bucket a large deterministic visitor-ID set across a 50/50
#      experience and assert each variation's share is within tolerance.
#
# TOLERANCE BOUNDS (documented per story requirement):
#   N = 10_000 deterministic visitor IDs ("visitor-0".."visitor-9999"), bucketed
#   across a 50/50 split. MurmurHash3 distributes uniformly over [0, 2^32), so the
#   expected per-variation share is 50%. We allow +/- 2.0 percentage points
#   (i.e. each variation lands in [48%, 52%], or [4800, 5200] of 10_000). This
#   band is the same order of magnitude as the PHP/JS distribution expectations
#   (a few hundred-basis-points of sampling slack at N=10k); it is wide enough to
#   never flake on a correct uniform hash yet tight enough to catch a broken
#   scale/truncate/range-walk (which would skew the split by tens of points).
#   The set and split are fixed, so the result is fully deterministic across runs.
RSpec.describe "Cross-SDK bucketing distribution & pipeline parity" do
  max_hash = 4_294_967_296 # 2^32
  max_traffic = 10_000
  bucketing_seed = 9999

  vectors_path = File.expand_path("../fixtures/cross_sdk/test-vectors.json", __dir__)
  all_vectors = JSON.parse(File.read(vectors_path))
  seed_9999_vectors = all_vectors.select { |v| v["seed"] == bucketing_seed }

  # A standalone Config supplies the frozen bucketing constants to the manager.
  let(:manager) { ConvertSdk::BucketingManager.new(config: ConvertSdk::Config.new(data: {})) }

  describe "pipeline parity vs vendored seed-9999 vectors (#{seed_9999_vectors.length})" do
    it "vendors the expected seed-9999 vector subset (guards against a truncated fixture)" do
      expect(seed_9999_vectors.length).to eq(15)
    end

    seed_9999_vectors.each do |vector|
      input = vector["input"]
      expected_hash = vector["expected"]
      # Mirror PHP: pass the vector input as the visitor id with an empty
      # experience id, so the hash input is exactly the vector input string.
      expected_normalized = ((expected_hash.to_f / max_hash) * max_traffic).to_i

      it "[#{vector["category"]}] normalizes #{input.inspect} to #{expected_normalized}" do
        actual = manager.value_visitor_based(input, experience_id: "", seed: bucketing_seed)
        expect(actual).to eq(expected_normalized)
      end
    end

    it "honours the canonical anchor (testString @ 9999 => normalized from 2241850228)" do
      expected = ((2_241_850_228.to_f / max_hash) * max_traffic).to_i
      expect(manager.value_visitor_based("testString", experience_id: "", seed: bucketing_seed))
        .to eq(expected)
    end
  end

  describe "distribution over a deterministic 10k visitor set (50/50 split)" do
    sample_size = 10_000
    experience_id = "100218245" # a real test-config experience id
    buckets = { "var-a" => 50, "var-b" => 50 }

    # Build the deterministic tally once; share the result across the per-variation
    # examples to avoid re-bucketing 10k IDs three times (and avoid duplication).
    let(:tally) do
      counts = Hash.new(0)
      sample_size.times do |i|
        result = manager.bucket_for_visitor(buckets, "visitor-#{i}", experience_id: experience_id)
        counts[result && result[:variation_id]] += 1
      end
      counts
    end

    it "assigns every visitor to one of the two variations (full coverage at 100%)" do
      expect(tally[nil]).to eq(0)
      expect(tally["var-a"] + tally["var-b"]).to eq(sample_size)
    end

    # Tolerance: 50% +/- 2.0pp => [4800, 5200] of 10_000 (see header rationale).
    { "var-a" => "first", "var-b" => "second" }.each do |variation_id, ordinal|
      it "allocates the #{ordinal} variation within +/-2pp of 50%" do
        expect(tally[variation_id]).to be_between(4_800, 5_200).inclusive
      end
    end

    it "is fully deterministic (re-bucketing the same set yields the same tally)" do
      again = Hash.new(0)
      sample_size.times do |i|
        result = manager.bucket_for_visitor(buckets, "visitor-#{i}", experience_id: experience_id)
        again[result && result[:variation_id]] += 1
      end
      expect(again).to eq(tally)
    end
  end
end
