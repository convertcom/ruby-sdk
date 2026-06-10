# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::BucketedFeature do
  # Snake_case members aligned to the JS BucketedFeature shape, verified against
  # javascript-sdk/packages/types/src/BucketedFeature.ts and the vendored
  # spec/fixtures/test-config.json feature entity.
  let(:attributes) do
    {
      experience_id: "100299",
      experience_key: "homepage-test",
      experience_name: "Homepage Test",
      id: "10024",
      key: "feature-1",
      name: "Feature 1",
      status: ConvertSdk::FeatureStatus::ENABLED,
      variables: { "enabled" => true, "caption" => "hello" }
    }
  end

  subject(:feature) { described_class.new(**attributes) }

  it "is frozen at construction" do
    expect(feature).to be_frozen
  end

  it "reports #error? false (it is a real decision, not a sentinel)" do
    expect(feature.error?).to be(false)
  end

  describe "member access" do
    attrs = %i[experience_id experience_key experience_name id key name status variables]
    attrs.each do |member|
      it "exposes ##{member}" do
        expect(feature.public_send(member)).to eq(attributes[member])
      end
    end
  end

  it "is a Struct subclass (3.1 floor — not Data.define)" do
    expect(described_class.ancestors).to include(Struct)
  end
end
