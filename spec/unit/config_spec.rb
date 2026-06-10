# frozen_string_literal: true

require "spec_helper"

# Story 2.4 — Configuration Surface & Fail-Fast Validation.
#
# This spec is the poster child for data-driven testing: the option surface is
# wide and uniform, so defaults, override merge, and the validation matrix are
# all exercised by iterating tables rather than copy-pasting near-identical
# examples (keeps SonarQube new_duplicated_lines_density well under the gate).
#
# Tables are top-level constants (RuboCop forbids constants inside blocks).

# Every public option => its JS-parity default value. Verified against
# javascript-sdk config/default.ts and php-sdk DefaultConfig.php on disk.
CONFIG_DEFAULTS_TABLE = {
  sdk_key: nil,
  sdk_key_secret: nil,
  data: nil,
  environment: nil,
  config_endpoint: "https://cdn-4.convertexperiments.com/api/v1",
  track_endpoint: "https://[project_id].metrics.convertexperiments.com/v1",
  max_traffic: 10_000,
  hash_seed: 9999,
  max_hash: 4_294_967_296,
  data_refresh_interval: 300,
  event_batch_size: 10,
  flush_interval: 1,
  keys_case_sensitive: true,
  negation: "!",
  log_level: ConvertSdk::LogLevel::DEBUG,
  tracking: true,
  open_timeout: 5,
  read_timeout: 10
}.freeze

# Each option => a non-default override value, to prove every option is settable
# and survives the snake_case -> internal translation round-trip.
CONFIG_OVERRIDE_TABLE = {
  sdk_key: "acct/proj",
  sdk_key_secret: "topsecretvalue",
  data: { "experiences" => [] },
  environment: "production",
  config_endpoint: "https://example.test/config",
  track_endpoint: "https://example.test/track",
  max_traffic: 5000,
  hash_seed: 1234,
  data_refresh_interval: 60,
  event_batch_size: 25,
  flush_interval: 2,
  keys_case_sensitive: false,
  negation: "NOT",
  log_level: ConvertSdk::LogLevel::WARN,
  tracking: false,
  open_timeout: 3,
  read_timeout: 7
}.freeze

# Validation matrix: each invalid kwargs payload => a Regexp the raised
# ArgumentError message must match (proves the message names the offending
# option). A baseline valid sdk_key is folded in so each row isolates ONE fault.
CONFIG_INVALID_TABLE = {
  "missing both sdk_key and data" => [{}, /sdk_key.*data|data.*sdk_key/i],
  "non-String sdk_key" => [{ sdk_key: 123 }, /sdk_key.*String/i],
  "non-String sdk_key_secret" => [{ sdk_key: "k", sdk_key_secret: 1 }, /sdk_key_secret.*String/i],
  "non-Hash data" => [{ data: "nope" }, /data.*Hash/i],
  "non-numeric data_refresh_interval" => [{ sdk_key: "k", data_refresh_interval: "x" }, /data_refresh_interval/i],
  "non-numeric flush_interval" => [{ sdk_key: "k", flush_interval: "x" }, /flush_interval/i],
  "non-Integer event_batch_size" => [{ sdk_key: "k", event_batch_size: 1.5 }, /event_batch_size.*Integer/i],
  "non-Integer max_traffic" => [{ sdk_key: "k", max_traffic: "big" }, /max_traffic.*Integer/i],
  "non-Integer hash_seed" => [{ sdk_key: "k", hash_seed: "seed" }, /hash_seed.*Integer/i],
  "unknown log_level" => [{ sdk_key: "k", log_level: 99 }, /log_level/i],
  "non-boolean keys_case_sensitive" => [{ sdk_key: "k", keys_case_sensitive: "yes" }, /keys_case_sensitive.*boolean/i],
  "non-boolean tracking" => [{ sdk_key: "k", tracking: "on" }, /tracking.*boolean/i],
  "non-String environment" => [{ sdk_key: "k", environment: 5 }, /environment.*String/i],
  "non-String negation" => [{ sdk_key: "k", negation: 0 }, /negation.*String/i],
  "non-String config_endpoint" => [{ sdk_key: "k", config_endpoint: 1 }, /config_endpoint.*String/i],
  "non-numeric open_timeout" => [{ sdk_key: "k", open_timeout: "x" }, /open_timeout/i],
  "non-numeric read_timeout" => [{ sdk_key: "k", read_timeout: "x" }, /read_timeout/i],
  "unknown option key" => [{ sdk_key: "k", bogus_option: true }, /bogus_option|unknown/i]
}.freeze

# sdk_key/sdk_key_secret/data are presence options the minimal valid config has
# to set or leave unset, so their defaults are asserted separately rather than in
# the swept defaults table.
CONFIG_PRESENCE_OPTIONS = %i[sdk_key sdk_key_secret data].freeze

RSpec.describe ConvertSdk::Config do
  # A minimal valid config (sdk_key satisfies the presence rule). Used wherever a
  # constructible instance is needed without restating every kwarg.
  def build(**overrides)
    described_class.new(sdk_key: "acct/proj", **overrides)
  end

  describe "DEFAULTS (AC#1)" do
    it "exposes a frozen DEFAULTS constant" do
      expect(described_class::DEFAULTS).to be_frozen
    end

    CONFIG_DEFAULTS_TABLE.except(*CONFIG_PRESENCE_OPTIONS).each do |option, expected|
      it "defaults ##{option} to its JS-parity value" do
        # max_hash has no kwarg (it is a fixed bucketing constant); read it off
        # the instance directly. Everything else has a like-named reader.
        config = build
        expect(config.public_send(option)).to eq(expected)
      end
    end

    it "defaults the presence options (sdk_key_secret/data) to nil in key mode" do
      config = build
      expect([config.sdk_key_secret, config.data]).to eq([nil, nil])
    end

    it "defaults sdk_key to nil in data-only mode" do
      expect(described_class.new(data: {}).sdk_key).to be_nil
    end

    it "freezes JS-parity bucketing constants to the exact frozen numbers" do
      config = build
      expect([config.hash_seed, config.max_traffic, config.max_hash])
        .to eq([9999, 10_000, 4_294_967_296])
    end
  end

  describe "override merge (AC#1)" do
    CONFIG_OVERRIDE_TABLE.each do |option, value|
      it "accepts an explicit ##{option} override over the default" do
        # Start from a presence-satisfying base (data: {}) then layer the single
        # option under test; building one kwargs hash avoids duplicate-kwarg
        # clashes when the option itself is sdk_key/data.
        kwargs = { data: {} }
        kwargs[option] = value
        config = described_class.new(**kwargs)
        expect(config.public_send(option)).to eq(value)
      end
    end
  end

  describe "wire-translation boundary #1 (AC#2)" do
    it "translates snake_case options into a string-keyed camelCase internal config" do
      internal = build(data_refresh_interval: 120, event_batch_size: 7).to_internal
      expect(internal).to include("sdkKey" => "acct/proj", "dataRefreshInterval" => 120, "batchSize" => 7)
    end

    it "translates flush_interval seconds into the internal millisecond wire value" do
      # Ruby surface is seconds (1s); the wire/internal value is milliseconds.
      expect(build(flush_interval: 2).to_internal["releaseInterval"]).to eq(2000)
    end

    it "returns a frozen internal config" do
      expect(build.to_internal).to be_frozen
    end

    it "carries the canonical flush_interval reader (event_release_interval is retired)" do
      expect(described_class.instance_methods).to include(:flush_interval)
      expect(described_class.instance_methods).not_to include(:event_release_interval)
    end
  end

  describe "nil-able timer intervals (AC#2)" do
    it "accepts a nil data_refresh_interval as timer-off" do
      expect(build(data_refresh_interval: nil).data_refresh_interval).to be_nil
    end

    it "accepts a nil flush_interval as timer-off" do
      expect(build(flush_interval: nil).flush_interval).to be_nil
    end

    it "emits a nil internal flush wire value when flush_interval is timer-off" do
      expect(build(flush_interval: nil).to_internal["releaseInterval"]).to be_nil
    end
  end

  describe "data-mode presence (AC#3)" do
    it "is constructible with data only and no sdk_key" do
      expect { described_class.new(data: { "experiences" => [] }) }.not_to raise_error
    end

    it "is constructible with sdk_key only and no data" do
      expect { described_class.new(sdk_key: "acct/proj") }.not_to raise_error
    end

    it "allows sdk_key and data to coexist" do
      expect { described_class.new(sdk_key: "acct/proj", data: {}) }.not_to raise_error
    end
  end

  describe "fail-fast validation — ArgumentError only (AC#3)" do
    CONFIG_INVALID_TABLE.each do |label, (kwargs, message_pattern)|
      it "raises ArgumentError on #{label}" do
        expect { described_class.new(**kwargs) }.to raise_error(ArgumentError, message_pattern)
      end
    end

    it "raises stdlib ArgumentError (no custom exception subclass)" do
      expect { described_class.new }.to(raise_error { |error| expect(error.class).to eq(ArgumentError) })
    end
  end

  describe "secret registration hook (NFR5)" do
    let(:registered) { [] }
    let(:log_manager) do
      instance = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::SILENT)
      collector = registered
      instance.define_singleton_method(:register_secret) { |secret| collector << secret }
      instance
    end

    it "registers sdk_key and sdk_key_secret with the LogManager" do
      described_class.new(sdk_key: "acct/proj", sdk_key_secret: "shh", log_manager: log_manager)
      expect(registered).to contain_exactly("acct/proj", "shh")
    end

    it "registers only sdk_key when no secret is given" do
      described_class.new(sdk_key: "acct/proj", log_manager: log_manager)
      expect(registered).to eq(["acct/proj"])
    end

    it "registers nothing extra in data-only mode with no key" do
      described_class.new(data: { "experiences" => [] }, log_manager: log_manager)
      expect(registered).to be_empty
    end

    it "is constructible standalone without a log_manager" do
      expect { described_class.new(sdk_key: "acct/proj") }.not_to raise_error
    end
  end
end
