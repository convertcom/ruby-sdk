# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::BucketedVariation do
  # Snake_case members aligned to the JS BucketedVariation shape
  # (ExperienceVariationConfig + experience fields), verified against
  # javascript-sdk/packages/types/src/BucketedVariation.ts and the vendored
  # spec/fixtures/test-config.json variation entity.
  let(:attributes) do
    {
      experience_id: "100299",
      experience_key: "homepage-test",
      experience_name: "Homepage Test",
      bucketing_allocation: 5000,
      id: "200381",
      key: "variation-a",
      name: "Variation A",
      status: "running",
      traffic_allocation: 10_000,
      changes: [{ id: "1", type: "customCode", data: {} }]
    }
  end

  subject(:variation) { described_class.new(**attributes) }

  it "is frozen at construction" do
    expect(variation).to be_frozen
  end

  it "reports #error? false (it is a real decision, not a sentinel)" do
    expect(variation.error?).to be(false)
  end

  it "exposes #key as the real variation key (not nil)" do
    expect(variation.key).to eq("variation-a")
  end

  describe "member access" do
    attrs = %i[
      experience_id experience_key experience_name bucketing_allocation
      id key name status traffic_allocation changes
    ]
    attrs.each do |member|
      it "exposes ##{member}" do
        expect(variation.public_send(member)).to eq(attributes[member])
      end
    end
  end

  it "is a Struct subclass (3.1 floor — not Data.define)" do
    expect(described_class.ancestors).to include(Struct)
  end
end
