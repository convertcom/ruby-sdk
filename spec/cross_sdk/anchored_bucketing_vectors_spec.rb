# frozen_string_literal: true

require "spec_helper"
require "json"

# Cross-SDK anchored bucketing layout parity (bucketing contract v12, qs-01).
#
# Story: ai-driven-product-dev
# _bmad-output/planning-artifacts/2026-06-05-convert-ruby-sdk/qs-01-anchored-bucketing-layout.md
#
# This is the release-blocking proof that the Ruby SDK's fresh-bucketing branch
# (DataManager#bucket_fresh) dispatches per experience["version"] EXACTLY like
# the JS reference: version > 11 -> the NEW anchored layout; version <= 11 /
# missing / non-numeric -> the EXISTING packed layout, bit-for-bit unchanged
# (AC1, AC6). The fixture also proves the anchored layout's own contract
# end-to-end (AC2 raise-superset, AC3 lower-ejection, AC4 stopped arms, AC5
# defaults/boundaries, AC7 golden vectors).
#
# The fixture is vendored VERBATIM from the JS reference SDK's open PR (see the
# qs-01 spec's "Golden-vector fixture" section) — its expected values ARE the
# cross-SDK contract. A failing vector is a bug in THIS Ruby port, never in the
# fixture; do not edit or recompute spec/fixtures/cross_sdk/cross-sdk-bucketing-
# vectors.json.
RSpec.describe "Cross-SDK anchored bucketing layout parity (contract v12)" do
  vectors_path = File.expand_path("../fixtures/cross_sdk/cross-sdk-bucketing-vectors.json", __dir__)
  vectors = JSON.parse(File.read(vectors_path))

  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: CapturingSink.new) }
  let(:config) { ConvertSdk::Config.new(data: {}) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  # No installed config, no store: DataManager#bucket_fresh takes the experience
  # hash directly as an argument and never reads @config for it, and a nil
  # data_store_manager makes #persist_bucketing a safe no-op. The golden vectors
  # carry no audience/location/environment data, so exercising the full public
  # decision flow (ExperienceManager#select_variation) would require inventing
  # unrelated fixture noise; going straight at the private fresh-bucketing
  # branch is the precise, minimal seam that owns the version gate (qs-01
  # "Where to change": "the data layer's fresh-bucketing branch").
  let(:data_manager) { ConvertSdk::DataManager.new(log_manager: log_manager, bucketing_manager: bucketing_manager) }

  # Resolve one golden vector (optionally overriding its version, for the
  # gate-branching section below) through DataManager#bucket_fresh directly.
  def resolve(vector, version: vector["version"])
    experience = {
      "id" => vector["experienceId"],
      "version" => version,
      "variations" => vector["variations"]
    }
    data_manager.send(:bucket_fresh, vector["visitorId"], experience, {})
  end

  it "vendors exactly 59 golden vectors (guards against a truncated/edited fixture)" do
    expect(vectors.length).to eq(59)
  end

  it "vendors both contract versions under test (11 packed, 12 anchored)" do
    expect(vectors.map { |v| v["version"] }.uniq.sort).to eq([11, 12])
  end

  # AC1 (version-exact dispatch) + AC2/AC3/AC4/AC5/AC6/AC7: one assertion per
  # vector, table-driven (no copy-pasted assertion blocks) — a null `expected`
  # means "not bucketed" (BucketingError::VARIATION_NOT_DECIDED); otherwise
  # `expected` is the winning variation id.
  describe "full golden-vector table (#{vectors.length} vectors: v11 packed + v12 anchored)" do
    vectors.each do |vector|
      expected = vector["expected"]

      it "[v#{vector["version"]}] #{vector["description"]}" do
        result = resolve(vector)

        if expected.nil?
          expect(result).to be(ConvertSdk::BucketingError::VARIATION_NOT_DECIDED)
        else
          expect(result).to be_a(ConvertSdk::BucketedVariation)
          expect(result.id).to eq(expected)
        end
      end
    end
  end

  describe "AC1 — gate branching mirrors the JS oracle's Number(version) > 11 coercion" do
    # Reuse a REAL golden vector's config (experience 900000001, thirds 15%:
    # O/V1/V2 @ 5% each) whose packed (v11) and anchored (v12) answers are
    # PROVEN to diverge for this exact visitor by the fixture itself: v11 ->
    # "V1" (packed band [500,1000) covers bucket value 601); v12 -> not
    # bucketed (anchored band [3333.33,3833.33) misses value 601). Found from
    # the fixture, never hand-copied. Any version whose JS `Number()` coercion
    # is NOT > 11 (missing, genuinely non-numeric, or numerically <= 11) MUST
    # take the packed branch and reproduce the v11 answer; any value whose
    # `Number()` coercion IS > 11 (including a numeric STRING like "12") MUST
    # take the anchored branch and reproduce the v12 answer.
    let(:base_vector) do
      vectors.find { |v| v["visitorId"] == "thirds-flip-V1-to-O-66" && v["version"] == 11 }
    end

    it "the fixture provides the diverging base vector this section depends on" do
      expect(base_vector).not_to be_nil
      expect(base_vector["expected"]).to eq("V1")
    end

    it "sanity: the SAME config diverges under an explicit v12 gate (not bucketed)" do
      expect(resolve(base_vector, version: 12)).to be(ConvertSdk::BucketingError::VARIATION_NOT_DECIDED)
    end

    {
      "missing (nil)" => nil,
      "genuinely non-numeric string 'twelve'" => "twelve",
      "exactly 11 (current production stamp)" => 11,
      "numeric but not greater than 11 (11.0)" => 11.0
    }.each do |label, version|
      it "routes #{label} to the PACKED layout (reproduces the v11 answer: V1)" do
        result = resolve(base_vector, version: version)
        expect(result).to be_a(ConvertSdk::BucketedVariation)
        expect(result.id).to eq("V1")
      end
    end

    {
      "12 (Integer)" => 12,
      "numeric string '12'" => "12",
      "11.5 (Float > 11)" => 11.5
    }.each do |label, version|
      it "routes #{label} to the ANCHORED layout (reproduces the v12 not-bucketed answer)" do
        expect(resolve(base_vector, version: version)).to be(ConvertSdk::BucketingError::VARIATION_NOT_DECIDED)
      end
    end
  end
end
