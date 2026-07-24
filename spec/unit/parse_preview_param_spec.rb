# frozen_string_literal: true

require "spec_helper"

# qs-03 (RB-2) — AC9: ConvertSdk.parse_preview_param, a pure helper mirroring
# the JS oracle (javascript-sdk packages/js-sdk/src/parse-preview-param.ts)
# exactly on splitting/validation, with the Ruby-specific return contract: a
# 2-element String array on success, nil on any malformed/non-String input.
#
# Table-driven (SonarCloud new_duplicated_lines_density gate) — one `it` per
# case via `each`, not copy-pasted per-row examples.
PARSE_PREVIEW_PARAM_CASES = [
  # [description, input, expected]
  ["dot-separated numeric ids", "123.456", %w[123 456]],
  ["both segments zero", "0.0", %w[0 0]],
  ["large numeric ids", "999999999.888888888", %w[999999999 888888888]],
  ["no dot at all", "123", nil],
  ["empty variation segment", "123.", nil],
  ["empty experience segment", ".456", nil],
  ["two dots", "1.2.3", nil],
  ["non-numeric segments", "a.b", nil],
  ["partial non-numeric variation segment", "12.3a", nil],
  ["empty string", "", nil],
  ["surrounding spaces make segments non-numeric", " 123.456 ", nil],
  ["nil input", nil, nil],
  ["non-String Float input", 123.456, nil],
  ["non-String Symbol input", :"1.2", nil]
].freeze

RSpec.describe "ConvertSdk.parse_preview_param" do
  PARSE_PREVIEW_PARAM_CASES.each do |description, input, expected|
    it "returns #{expected.inspect} for #{description} (#{input.inspect})" do
      expect(ConvertSdk.parse_preview_param(input)).to eq(expected)
    end
  end

  it "is pure: never raises for any case above" do
    aggregate_failures do
      PARSE_PREVIEW_PARAM_CASES.each do |description, input, _expected|
        expect { ConvertSdk.parse_preview_param(input) }.not_to raise_error, "raised for #{description}"
      end
    end
  end
end
