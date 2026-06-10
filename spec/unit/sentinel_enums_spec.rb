# frozen_string_literal: true

require "spec_helper"

# Tabular, data-driven assertion of every sentinel enum constant against its
# byte-identical JS wire string. The wire strings are bytes on the wire — they
# appear in payloads/logs and MUST match the JS SDK exactly. The local Ruby
# constant spelling for BucketingError is CORRECTED from the JS typo
# (JS: VARIAION_NOT_DECIDED) while the wire string is left byte-identical.
#
# Verified against javascript-sdk/packages/enums/src/{rule-error,bucketing-error}.ts
SENTINEL_ENUM_WIRE = {
  ConvertSdk::RuleError::NO_DATA_FOUND => "convert.com_no_data_found",
  ConvertSdk::RuleError::NEED_MORE_DATA => "convert.com_need_more_data",
  ConvertSdk::BucketingError::VARIATION_NOT_DECIDED => "convert.com_variation_not_decided"
}.freeze

RSpec.describe "Sentinel singleton enums" do
  SENTINEL_ENUM_WIRE.each do |sentinel, expected_wire|
    context "the sentinel emitting #{expected_wire.inspect}" do
      it "is a ConvertSdk::Sentinel" do
        expect(sentinel).to be_a(ConvertSdk::Sentinel)
      end

      it "exposes the byte-identical JS wire string via #to_s" do
        expect(sentinel.to_s).to eq(expected_wire)
      end

      it "reports #error? true" do
        expect(sentinel.error?).to be(true)
      end

      it "reports #key nil so `case variation&.key` falls through" do
        expect(sentinel.key).to be_nil
      end

      it "is a frozen singleton" do
        expect(sentinel).to be_frozen
      end
    end
  end

  it "exposes each sentinel as a stable singleton (identity comparison)" do
    expect(ConvertSdk::RuleError::NO_DATA_FOUND)
      .to be(ConvertSdk::RuleError::NO_DATA_FOUND)
  end

  it "uses distinct singletons for distinct misses" do
    expect(ConvertSdk::RuleError::NO_DATA_FOUND)
      .not_to be(ConvertSdk::RuleError::NEED_MORE_DATA)
  end
end
