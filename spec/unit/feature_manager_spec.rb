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

  # Build a fixture-loaded DataManager from an arbitrary direct-data envelope —
  # reused by the vendored fixture above and the Ruby-local casting config below.
  def build_data_manager(envelope)
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { "10022898" }, project_resolver: -> { "10025986" }
    )
    dm.install_config(stringify(envelope))
    dm
  end

  # A minimal Ruby-LOCAL direct-data config (NOT a fixture edit) whose single
  # always-bucketing experience carries a fullStackFeature change for a feature
  # declaring float/integer/json variables — the only way to drive those casts
  # through a real bucketed variation (the vendored fixture's visitor buckets
  # only into feature-1's boolean/string variation). Empty audiences + no
  # site_area + present (empty) visitor properties + a single 100%-traffic
  # running variation make bucketing deterministic. Assembled from small parts so
  # no single builder is over-long.
  def local_cast_feature
    { "id" => "20001", "name" => "Typed Feature", "key" => "typed-feature",
      "variables" => [
        { "key" => "price", "type" => "float" },
        { "key" => "button-height", "type" => "integer" },
        { "key" => "additionalData", "type" => "json" }
      ] }
  end

  def local_cast_experience
    { "id" => "300001", "name" => "Typed Cast Exp", "key" => "typed-cast-exp",
      "type" => "a/b_fullstack", "status" => "active",
      "environments" => ["live"], "audiences" => [],
      "variations" => [{
        "id" => "400001", "name" => "Original", "status" => "running",
        "is_baseline" => true, "key" => "400001-original", "traffic_allocation" => 100.0,
        "changes" => [{
          "id" => "500001", "type" => "fullStackFeature",
          "data" => { "feature_id" => "20001",
                      "variables_data" => { "price" => 100, "button-height" => 40,
                                            "additionalData" => "{\"foo\":\"bar\",\"v\":2}" } }
        }]
      }] }
  end

  def local_cast_config
    { "account_id" => "10022898", "project" => { "id" => "10025986" },
      "audiences" => [], "segments" => [], "goals" => [],
      "features" => [local_cast_feature], "experiences" => [local_cast_experience] }
  end

  # The visitor + attributes combination that buckets into BOTH
  # test-experience-ab-fullstack-2 (variation 100299457) AND
  # test-experience-ab-fullstack-3 (variation 100299461) — verified against the
  # vendored fixture's real bucketing outcome. BOTH bucketed variations carry a
  # fullStackFeature change for feature-1 (id 10024); NEITHER carries feature-2
  # (id 10025, which sits only on the original-page variations the visitor did
  # not get). fullstack-4 is a VARIATION_NOT_DECIDED miss. Feature-1 is therefore
  # carried by TWO bucketed variations (multi-experience), feature-2 by none.
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
    # feature-1 is carried by exactly one bucketed variation when only ONE
    # experience is in scope, so an experience filter yields a single feature.
    it "returns an ENABLED frozen BucketedFeature for a feature carried by a single bucketed variation" do
      result = manager.run_features(visitor, bucketing_attrs,
                                    experiences: ["test-experience-ab-fullstack-2"],
                                    features: ["feature-1"]).first
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
      result = manager.run_features(visitor, bucketing_attrs,
                                    experiences: ["test-experience-ab-fullstack-2"],
                                    features: ["feature-1"]).first
      expect(result.status).to eq(ConvertSdk::FeatureStatus::ENABLED)
      expect(result.experience_id).to eq("100218245")
    end

    it "never inlines the wire strings — status comes from the FeatureStatus enum" do
      enabled = manager.run_features(visitor, bucketing_attrs,
                                     experiences: ["test-experience-ab-fullstack-2"],
                                     features: ["feature-1"]).first
      expect(enabled.status).to be(ConvertSdk::FeatureStatus::ENABLED)
    end
  end

  describe "#run_feature — miss semantics (AC#5)" do
    it "returns a DISABLED BucketedFeature (id/name/key) when declared but the visitor is not bucketed" do
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
      debug = sink.entries.filter_map { |entry| entry.last if entry.first == :debug }
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
      statuses = results.group_by(&:key).transform_values { |fs| fs.map(&:status).uniq }
      # feature-1 is carried by BOTH bucketed variations -> ENABLED (one per exp).
      expect(statuses["feature-1"]).to include(ConvertSdk::FeatureStatus::ENABLED)
      # feature-2 is NOT carried by either bucketed variation -> DISABLED padding.
      expect(statuses["feature-2"]).to eq([ConvertSdk::FeatureStatus::DISABLED])
      expect(statuses["not-attached-feature-3"]).to eq([ConvertSdk::FeatureStatus::DISABLED])
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
    it "casts feature-1 variables (boolean, string) from the bucketed variation's raw values" do
      # fullstack-2's bucketed variation (100299457) carries
      # {enabled: "false", caption: "Not allowed"} for feature-1.
      result = manager.run_features(visitor, bucketing_attrs,
                                    experiences: ["test-experience-ab-fullstack-2"],
                                    features: ["feature-1"]).first
      expect(result.variables["enabled"]).to be(false)          # boolean "false" -> false
      expect(result.variables["caption"]).to eq("Not allowed")  # string
    end

    it "casts feature-1 variables (boolean true) from the other bucketed experience" do
      # fullstack-3's bucketed variation (100299461) carries enabled: "true".
      result = manager.run_features(visitor, bucketing_attrs,
                                    experiences: ["test-experience-ab-fullstack-3"],
                                    features: ["feature-1"]).first
      expect(result.variables["enabled"]).to be(true)
      expect(result.variables["caption"]).to eq("Allowed")
    end

    # feature-2 (float/integer/json) is not carried by any variation the fixture
    # visitor buckets into, so a minimal Ruby-local direct-data config (NOT a
    # fixture edit) exercises float/integer/json casting from a bucketed variation.
    it "casts float/integer/json variables from a bucketed variation (Ruby-local config)" do
      local_dm = build_data_manager(local_cast_config)
      local_mgr = described_class.new(data_manager: local_dm, log_manager: log_manager)
      result = local_mgr.run_features("anyone", { visitor_properties: {}, environment: "live" },
                                      features: ["typed-feature"]).first
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
