# frozen_string_literal: true

require "spec_helper"

# Tabular, data-driven assertion of every plain-enum constant against its
# byte-identical JS wire value. Verified against
# javascript-sdk/packages/enums/src/{feature-status,log-level,system-events,goal-data-key}.ts
#
# String enums: each constant -> expected byte string, and each must be frozen.
STRING_ENUM_WIRE = {
  ConvertSdk::FeatureStatus::ENABLED => "enabled",
  ConvertSdk::FeatureStatus::DISABLED => "disabled",
  ConvertSdk::SystemEvents::READY => "ready",
  ConvertSdk::SystemEvents::CONFIG_UPDATED => "config.updated",
  ConvertSdk::SystemEvents::BUCKETING => "bucketing",
  ConvertSdk::SystemEvents::CONVERSION => "conversion",
  ConvertSdk::SystemEvents::API_QUEUE_RELEASED => "api.queue.released",
  ConvertSdk::SystemEvents::SEGMENTS => "segments",
  ConvertSdk::SystemEvents::LOCATION_ACTIVATED => "location.activated",
  ConvertSdk::SystemEvents::LOCATION_DEACTIVATED => "location.deactivated",
  ConvertSdk::SystemEvents::AUDIENCES => "audiences",
  ConvertSdk::SystemEvents::DATASTORE_QUEUE_RELEASED => "datastore.queue.released",
  ConvertSdk::GoalDataKey::AMOUNT => "amount",
  ConvertSdk::GoalDataKey::PRODUCTS_COUNT => "productsCount",
  ConvertSdk::GoalDataKey::TRANSACTION_ID => "transactionId",
  ConvertSdk::GoalDataKey::CUSTOM_DIMENSION_1 => "customDimension1",
  ConvertSdk::GoalDataKey::CUSTOM_DIMENSION_2 => "customDimension2",
  ConvertSdk::GoalDataKey::CUSTOM_DIMENSION_3 => "customDimension3",
  ConvertSdk::GoalDataKey::CUSTOM_DIMENSION_4 => "customDimension4",
  ConvertSdk::GoalDataKey::CUSTOM_DIMENSION_5 => "customDimension5"
}.freeze

# Integer enum: JS-parity name -> integer. Order/value verified vs log-level.ts.
LOG_LEVEL_VALUE = {
  ConvertSdk::LogLevel::TRACE => 0,
  ConvertSdk::LogLevel::DEBUG => 1,
  ConvertSdk::LogLevel::INFO => 2,
  ConvertSdk::LogLevel::WARN => 3,
  ConvertSdk::LogLevel::ERROR => 4,
  ConvertSdk::LogLevel::SILENT => 5
}.freeze

RSpec.describe "Plain enums" do
  STRING_ENUM_WIRE.each do |actual, expected|
    it "string enum #{expected.inspect} is the byte-identical frozen wire value" do
      expect(actual).to eq(expected)
      expect(actual).to be_frozen
    end
  end

  LOG_LEVEL_VALUE.each do |actual, expected|
    it "LogLevel value #{expected} matches JS-parity integer" do
      expect(actual).to eq(expected)
    end
  end

  describe ConvertSdk::GoalDataKey do
    it "exposes ALL as a frozen array of the 8 keys in declaration order" do
      expect(described_class::ALL).to eq(
        %w[
          amount productsCount transactionId
          customDimension1 customDimension2 customDimension3
          customDimension4 customDimension5
        ]
      )
      expect(described_class::ALL).to be_frozen
    end
  end
end
