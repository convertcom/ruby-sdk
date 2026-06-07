# frozen_string_literal: true

require "spec_helper"

# Story 3.1 — FeatureManager: resolution through the 2.11 bucketing flow +
# typed-variable casting. A feature is ENABLED exactly when the visitor is
# bucketed (via DataManager#get_bucketing) into a variation carrying a
# +fullStackFeature+ change whose +data.feature_id+ matches the feature. The
# manager is a MAPPING + CASTING layer over the existing decision flow — it
# never re-evaluates rules.
RSpec.describe ConvertSdk::FeatureManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }

  # DataManager loaded with the vendored fixture (direct-data) + decisioning
  # collaborators, so get_bucketing decides against real experiences/variations.
  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { ConfigFixture.account_id },
      project_resolver: -> { ConfigFixture.project_id }
    )
    dm.install_config(stringify(ConfigFixture.config))
    dm
  end

  subject(:manager) { described_class.new(data_manager: data_manager, log_manager: log_manager) }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # The visitor + attributes combination that buckets into
  # test-experience-ab-fullstack-2 (verified in context_spec / Story 2.11). That
  # experience's variations carry fullStackFeature changes for feature-1 (10024)
  # and feature-2 (10025).
  let(:visitor) { "visitor-1" }
  let(:bucketing_attrs) do
    { visitor_properties: { "varName1" => "value1", "varName2" => "value2" },
      location_properties: nil, environment: "staging" }
  end
  # Attributes that match NO audience — the visitor is not bucketed anywhere.
  let(:miss_attrs) do
    { visitor_properties: { "varName1" => "no", "varName2" => "no" },
      location_properties: nil, environment: "staging" }
  end

  describe "#run_feature — resolution through bucketing (AC#1, #3)" do
    it "returns an ENABLED frozen BucketedFeature for a feature carried by the bucketed variation" do
      result = manager.run_feature(visitor, "feature-1", bucketing_attrs)
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::ENABLED)
      expect(result).to be_frozen
      expect(result.key).to eq("feature-1")
      expect(result.id).to eq("10024")
      expect(result.name).to eq("Feature 1")
      expect(result.experience_key).to eq("test-experience-ab-fullstack-2")
      expect(result.error?).to be(false)
    end

    it "carries the experience provenance from the bucketed variation" do
      result = manager.run_feature(visitor, "feature-2", bucketing_attrs)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::ENABLED)
      expect(result.experience_id).to eq("100218245")
    end

    it "never inlines the wire strings — status comes from the FeatureStatus enum" do
      enabled = manager.run_feature(visitor, "feature-1", bucketing_attrs)
      expect(enabled.status).to be(ConvertSdk::FeatureStatus::ENABLED)
    end
  end

  describe "#run_feature — miss semantics (AC#5)" do
    it "returns a DISABLED BucketedFeature (id/name/key) when the feature is declared but the visitor is not bucketed" do
      result = manager.run_feature(visitor, "feature-1", miss_attrs)
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.key).to eq("feature-1")
      expect(result.id).to eq("10024")
      expect(result.name).to eq("Feature 1")
      expect(result).to be_frozen
    end

    it "returns a DISABLED BucketedFeature (key only) when the feature is NOT declared at all" do
      result = manager.run_feature(visitor, "no-such-feature", bucketing_attrs)
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.key).to eq("no-such-feature")
      expect(result.id).to be_nil
    end

    it "emits a debug reason log on a miss (Ruby addition; never an exception)" do
      manager.run_feature(visitor, "feature-1", miss_attrs)
      debug = sink.entries.select { |level, _| level == :debug }.map(&:last)
      expect(debug.join("\n")).to include("FeatureManager")
    end

    it "returns DISABLED when the feature is declared but carried by no variation the visitor hits" do
      # not-attached-feature-3 is declared but attached to no experience variation.
      result = manager.run_feature(visitor, "not-attached-feature-3", bucketing_attrs)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.key).to eq("not-attached-feature-3")
    end
  end

  describe "#run_features — all applicable features (AC#2)" do
    it "returns ENABLED features for carried variations PLUS DISABLED for every other declared feature (no filter)" do
      results = manager.run_features(visitor, bucketing_attrs)
      expect(results).to be_an(Array)
      expect(results).to all(be_a(ConvertSdk::BucketedFeature))
      by_key = results.each_with_object({}) { |f, h| h[f.key] = f.status }
      expect(by_key["feature-1"]).to eq(ConvertSdk::FeatureStatus::ENABLED)
      expect(by_key["feature-2"]).to eq(ConvertSdk::FeatureStatus::ENABLED)
      expect(by_key["not-attached-feature-3"]).to eq(ConvertSdk::FeatureStatus::DISABLED)
    end

    it "returns every declared feature as DISABLED when the visitor is bucketed nowhere" do
      results = manager.run_features(visitor, miss_attrs)
      expect(results).to all(have_attributes(status: ConvertSdk::FeatureStatus::DISABLED))
      expect(results.map(&:key)).to contain_exactly("feature-1", "feature-2", "not-attached-feature-3")
    end
  end

  describe "#run_features — multiple experiences carrying the same feature (AC#3)" do
    it "returns one ENABLED BucketedFeature per carrying variation" do
      # feature-1 is carried by fullstack-2 AND fullstack-3. With no feature
      # filter the visitor's bucketed variations across both contribute it.
      results = manager.run_features(visitor, bucketing_attrs)
      f1 = results.select { |f| f.key == "feature-1" && f.status == ConvertSdk::FeatureStatus::ENABLED }
      expect(f1.size).to be >= 1
    end
  end

  describe "typed-variable casting (AC#4) — JS castType parity" do
    it "casts feature-1 variables per declared types (boolean, string)" do
      result = manager.run_feature(visitor, "feature-1", bucketing_attrs)
      expect(result.variables["enabled"]).to be(true)          # boolean "true" -> true
      expect(result.variables["caption"]).to eq("Click that")  # string
    end

    it "casts feature-2 variables per declared types (float, integer, json)" do
      result = manager.run_feature(visitor, "feature-2", bucketing_attrs)
      expect(result.variables["price"]).to eq(100.0)
      expect(result.variables["price"]).to be_a(Float)
      expect(result.variables["button-height"]).to eq(40)
      expect(result.variables["button-height"]).to be_a(Integer)
      expect(result.variables["additionalData"]).to eq({ "foo" => "bar", "v" => 2 })
    end

    # The casting truth table — ONE tabular spec over (declared type x input x
    # expected). Exercises cast_type directly so cast-failure / edge paths are
    # covered without per-type copy-paste (duplication discipline).
    describe "#cast_type truth table" do
      [
        ["string", "hello", "hello"],
        ["string", 42, "42"],
        ["string", true, "true"],
        ["boolean", "true", true],
        ["boolean", "false", false],
        ["boolean", "anything", true],
        ["boolean", "", false],
        ["integer", "40", 40],
        ["integer", true, 1],
        ["integer", false, 0],
        ["integer", "12abc", 12],
        ["float", "3.14", 3.14],
        ["float", true, 1.0],
        ["float", false, 0.0],
        ["json", "{\"a\":1}", { "a" => 1 }],
        ["json", "[1,2,3]", [1, 2, 3]],
        ["json", "not json", "not json"],     # parse failure -> raw string
        ["json", { "a" => 1 }, { "a" => 1 }], # already an object -> as-is
        ["unknown-type", "raw", "raw"]        # default -> value unchanged
      ].each do |type, input, expected|
        it "casts #{input.inspect} as #{type} to #{expected.inspect}" do
          expect(manager.cast_type(input, type)).to eq(expected)
        end
      end

      it "never raises on an uncastable integer input" do
        expect { manager.cast_type("garbage", "integer") }.not_to raise_error
      end

      it "never raises on an uncastable float input" do
        expect { manager.cast_type("garbage", "float") }.not_to raise_error
      end
    end
  end

  describe "NFR1 — zero network/disk I/O on cached-config evaluation" do
    it "performs no HTTP request during run_features" do
      manager.run_features(visitor, bucketing_attrs)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end
end
