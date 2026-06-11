# frozen_string_literal: true

require "spec_helper"

# Decision-flow + variation-selection specs for the Epic 2 assembly (Story 2.11).
#
# ExperienceManager is the thin variation-selection support surface (mirrors JS
# experience-manager.ts): it wraps DataManager's decision flow with the per-key
# (+select_variation+) and across-all-experiences (+select_variations+) entry
# points. The ORDERED decision flow itself lives in DataManager
# (+get_bucketing+ -> +match_rules_by_field+ -> +retrieve_bucketing+), mirroring
# the JS division of labor (data-manager.ts:227-720).
#
# The flow ORDER is JS-pinned (technical research §Decision-Flow / data-manager.ts:302
# of the research doc). A reordered step is a parity bug even when each step is
# individually correct, so the order is asserted explicitly via collaborator spies.
RSpec.describe ConvertSdk::ExperienceManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }

  # DataManager wired with the decisioning collaborators and the fixture config.
  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager,
      data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager,
      rule_manager: rule_manager,
      account_resolver: -> { ConfigFixture.account_id },
      project_resolver: -> { ConfigFixture.project_id }
    )
    dm.install_config(stringify(ConfigFixture.config))
    dm
  end

  let(:experience_manager) { described_class.new(data_manager: data_manager, log_manager: log_manager) }

  # Fixture experience keys/ids (verified from spec/fixtures/test-config.json).
  let(:exp_key) { "test-experience-ab-fullstack-2" }
  let(:exp_id) { "100218245" }
  # The two running variations of exp1 (both traffic_allocation 50.0).
  let(:variation_ids) { %w[100299456 100299457] }
  let(:visitor) { "visitor-xyz" }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # Visitor properties that SATISFY the transient audience 100299433 (its rules
  # require varName1=value1 AND varName2=value2, matched case-insensitively).
  let(:matching_props) { { "varName1" => "value1", "varName2" => "value2" } }
  # Visitor properties that FAIL the audience (wrong value).
  let(:failing_props) { { "varName1" => "nope", "varName2" => "nope" } }

  # Bucketing-attributes builder: environment matches the fixture top-level
  # ("staging"); visitor_properties drive the audience step.
  def attrs(visitor_properties: matching_props, **extra)
    { visitor_properties: visitor_properties, environment: "staging" }.merge(extra)
  end

  describe "#select_variation — happy path (AC#1)" do
    it "returns a frozen BucketedVariation for an eligible visitor" do
      result = experience_manager.select_variation(visitor, exp_key, attrs)
      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(result).to be_frozen
      expect(result.error?).to be(false)
    end

    it "carries the experience identity and a real variation id/key" do
      result = experience_manager.select_variation(visitor, exp_key, attrs)
      expect(result.experience_id).to eq(exp_id)
      expect(result.experience_key).to eq(exp_key)
      expect(variation_ids).to include(result.id)
      expect(result.key).to be_a(String)
    end

    it "is deterministic — same visitor buckets to the same variation" do
      a = experience_manager.select_variation(visitor, exp_key, attrs)
      b = experience_manager.select_variation("other-visitor-2", exp_key, attrs)
      again = experience_manager.select_variation(visitor, exp_key, attrs)
      expect(again.id).to eq(a.id)
      expect([a, b].map(&:id)).to all(satisfy { |id| variation_ids.include?(id) })
    end
  end

  describe "ordered decision flow — miss sentinels + debug-log pairing (AC#5)" do
    # Each row: a config mutation producing a miss at a specific step, the
    # expected sentinel, and a debug-log fragment naming the failed step. Driven
    # tabularly (NOT copy-pasted per step) to avoid duplication.
    {
      "unknown experience (entity miss)" => {
        mutate: ->(_cfg) {}, key: "no-such-experience",
        sentinel: ConvertSdk::RuleError::NO_DATA_FOUND, log: "no experience"
      },
      "archived experience" => {
        mutate: lambda { |cfg|
          cfg["archived_experiences"] = [100_218_245]
        },
        key: nil, sentinel: ConvertSdk::RuleError::NO_DATA_FOUND, log: "archived"
      },
      "environment mismatch" => {
        mutate: lambda { |cfg|
          cfg["experiences"][0]["environment"] = "live"
        },
        key: nil, sentinel: ConvertSdk::RuleError::NO_DATA_FOUND, log: "environment",
        attrs: { environment: "staging" }
      },
      "audience fails" => {
        mutate: ->(_cfg) {}, key: nil,
        sentinel: ConvertSdk::RuleError::NO_DATA_FOUND, log: "audience",
        props: { "varName1" => "nope", "varName2" => "nope" }
      },
      "zero traffic (no variation decided)" => {
        mutate: lambda { |cfg|
          cfg["experiences"][0]["variations"].each { |v| v["traffic_allocation"] = 0.0 }
        },
        key: nil, sentinel: ConvertSdk::BucketingError::VARIATION_NOT_DECIDED, log: "bucket"
      }
    }.each do |label, spec|
      it "returns #{spec[:sentinel]} with a debug log on #{label}" do
        cfg = stringify(ConfigFixture.config)
        spec[:mutate].call(cfg)
        dm = ConvertSdk::DataManager.new(
          log_manager: log_manager, data_store_manager: data_store_manager,
          bucketing_manager: bucketing_manager, rule_manager: rule_manager,
          account_resolver: -> { ConfigFixture.account_id },
          project_resolver: -> { ConfigFixture.project_id }
        )
        dm.install_config(cfg)
        em = described_class.new(data_manager: dm, log_manager: log_manager)
        key = spec[:key] || exp_key
        a = attrs(visitor_properties: spec[:props] || matching_props).merge(spec[:attrs] || {})
        result = em.select_variation(visitor, key, a)
        expect(result).to be(spec[:sentinel])
        expect(result.key).to be_nil
        expect(sink.joined.downcase).to include(spec[:log])
      end
    end
  end

  describe "step ORDER proof — early exit skips later steps (AC#1)" do
    it "an archived experience never reaches audience/rule evaluation" do
      cfg = stringify(ConfigFixture.config)
      cfg["archived_experiences"] = [100_218_245]
      dm = ConvertSdk::DataManager.new(
        log_manager: log_manager, data_store_manager: data_store_manager,
        bucketing_manager: bucketing_manager, rule_manager: rule_manager,
        account_resolver: -> { ConfigFixture.account_id },
        project_resolver: -> { ConfigFixture.project_id }
      )
      dm.install_config(cfg)
      em = described_class.new(data_manager: dm, log_manager: log_manager)
      # RuleManager must NOT be consulted: archived short-circuits before audiences.
      expect(rule_manager).not_to receive(:is_rule_matched)
      em.select_variation(visitor, exp_key, attrs)
    end

    it "a failing audience never reaches bucketing (variation selection)" do
      expect(bucketing_manager).not_to receive(:bucket_for_visitor)
      experience_manager.select_variation(visitor, exp_key, attrs(visitor_properties: failing_props))
    end
  end

  describe "nil visitor_properties gates the experience (JS parity)" do
    # JS data-manager.ts:356-416: audiencesMatched defaults false and is only set
    # inside `if (visitorProperties)`, so a nil bag is never eligible — even with
    # no attached audiences. A present-but-empty {} bag is a different case.
    it "returns NO_DATA_FOUND when visitor_properties is nil" do
      result = experience_manager.select_variation(visitor, exp_key, { environment: "staging" })
      expect(result).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end
  end

  describe "empty locations / no site_area restriction (AC#4)" do
    it "treats an experience with no locations and no site_area as unrestricted" do
      cfg = stringify(ConfigFixture.config)
      cfg["experiences"][0].delete("site_area")
      cfg["experiences"][0].delete("locations")
      dm = ConvertSdk::DataManager.new(
        log_manager: log_manager, data_store_manager: data_store_manager,
        bucketing_manager: bucketing_manager, rule_manager: rule_manager,
        account_resolver: -> { ConfigFixture.account_id },
        project_resolver: -> { ConfigFixture.project_id }
      )
      dm.install_config(cfg)
      em = described_class.new(data_manager: dm, log_manager: log_manager)
      result = em.select_variation(visitor, exp_key, attrs)
      expect(result).to be_a(ConvertSdk::BucketedVariation)
    end
  end

  describe "#select_variations — across all experiences, misses filtered (AC#2)" do
    it "returns only successful BucketedVariations (misses excluded, JS parity)" do
      results = experience_manager.select_variations(visitor, attrs)
      expect(results).to be_an(Array)
      expect(results).to all(be_a(ConvertSdk::BucketedVariation))
    end

    it "filters out experiences whose audience fails (no sentinels in the list)" do
      results = experience_manager.select_variations(visitor, attrs(visitor_properties: failing_props))
      expect(results).to be_empty
    end
  end
end
