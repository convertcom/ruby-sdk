# frozen_string_literal: true

require "spec_helper"

# Sticky-bucketing + audience permanent/transient + config-drift specs
# (Story 2.11 Task 2 — decided behavior, human decision 2026-06-07).
#
# These exercise the DataManager decision flow's stored-bucketing path:
#  * On a fresh successful bucketing the {experience_id => variation_id} pair is
#    persisted into the visitor's StoreData "bucketing" map (atomic merge through
#    DataStoreManager, story 2.1).
#  * On re-run the stored decision is returned, rehydrated as a frozen
#    BucketedVariation from the CURRENT config entities (store read asserted).
#  * PERMANENT audiences are skipped once bucketed; TRANSIENT audiences are
#    re-evaluated on EVERY check (a failing transient gates the experience even
#    for an already-bucketed visitor).
#  * Config drift: a stored variation_id no longer present in the config makes
#    the stored decision unusable -> the visitor is treated as not bucketed and
#    silently re-bucketed (no error, no ghost variation).
RSpec.describe "Sticky bucketing decision flow" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }

  let(:exp_key) { "test-experience-ab-fullstack-2" }
  let(:exp_id) { "100218245" }
  let(:variation_ids) { %w[100299456 100299457] }
  let(:visitor) { "sticky-visitor-1" }
  let(:matching_props) { { "varName1" => "value1", "varName2" => "value2" } }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # Build a DataManager + ExperienceManager pair from a (possibly mutated) config.
  def build(cfg = stringify(ConfigFixture.config))
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { ConfigFixture.account_id },
      project_resolver: -> { ConfigFixture.project_id }
    )
    dm.install_config(cfg)
    ConvertSdk::ExperienceManager.new(data_manager: dm, log_manager: log_manager)
  end

  def store_key
    data_store_manager.visitor_key(ConfigFixture.account_id, ConfigFixture.project_id, visitor)
  end

  def attrs(visitor_properties: matching_props, **extra)
    { visitor_properties: visitor_properties, environment: "staging" }.merge(extra)
  end

  describe "persistence on successful bucketing (AC#3)" do
    it "stores {experience_id => variation_id} in the visitor's bucketing map" do
      em = build
      result = em.select_variation(visitor, exp_key, attrs)
      stored = store.get(store_key)
      expect(stored["bucketing"][exp_id]).to eq(result.id)
    end

    it "merges (does not clobber) existing visitor StoreData" do
      data_store_manager.merge_visitor_data(
        ConfigFixture.account_id, ConfigFixture.project_id, visitor
      ) { |_c| { "segments" => { "plan" => "pro" } } }
      build.select_variation(visitor, exp_key, attrs)
      stored = store.get(store_key)
      expect(stored["segments"]).to eq({ "plan" => "pro" })
      expect(stored["bucketing"]).to have_key(exp_id)
    end
  end

  describe "re-run returns the stored decision (sticky)" do
    it "returns the SAME variation on re-run, reading from the store" do
      em = build
      first = em.select_variation(visitor, exp_key, attrs)
      # On re-run the stored variation must be returned without re-bucketing.
      expect(bucketing_manager).not_to receive(:bucket_for_visitor)
      second = build.select_variation(visitor, exp_key, attrs)
      expect(second.id).to eq(first.id)
      expect(second).to be_a(ConvertSdk::BucketedVariation)
      expect(second).to be_frozen
    end
  end

  describe "permanent vs transient audience re-evaluation (AC#3)" do
    # Make the experience's audience PERMANENT so it is skipped once bucketed.
    def permanent_config
      cfg = stringify(ConfigFixture.config)
      cfg["audiences"].each { |a| a["type"] = "permanent" }
      cfg
    end

    it "skips PERMANENT audiences once the visitor is bucketed" do
      # Bucket once with matching props (audience passes).
      build(permanent_config).select_variation(visitor, exp_key, attrs)
      # Re-run with FAILING props: a permanent audience is skipped -> stored
      # decision still returned (no audience gate on re-run).
      result = build(permanent_config).select_variation(
        visitor, exp_key, attrs(visitor_properties: { "varName1" => "nope", "varName2" => "nope" })
      )
      expect(result).to be_a(ConvertSdk::BucketedVariation)
    end

    it "RE-EVALUATES TRANSIENT audiences even when already bucketed (gates on failure)" do
      # Fixture audience 100299433 is transient. Bucket once (passes).
      em = build
      first = em.select_variation(visitor, exp_key, attrs)
      expect(first).to be_a(ConvertSdk::BucketedVariation)
      # Re-run with FAILING props: transient audience re-evaluated -> gated.
      gated = build.select_variation(
        visitor, exp_key, attrs(visitor_properties: { "varName1" => "nope", "varName2" => "nope" })
      )
      expect(gated).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end
  end

  describe "config drift — stored variation removed from config" do
    it "silently re-buckets into a current running variation (no error, no ghost)" do
      # Seed a stored bucketing pointing at a variation id that does NOT exist in
      # the current config.
      data_store_manager.merge_visitor_data(
        ConfigFixture.account_id, ConfigFixture.project_id, visitor
      ) { |_c| { "bucketing" => { exp_id => "999999999-ghost" } } }

      result = build.select_variation(visitor, exp_key, attrs)
      # A clean re-bucket into one of the real running variations; never the ghost.
      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(variation_ids).to include(result.id)
      expect(result.id).not_to eq("999999999-ghost")
      # And the store is corrected to the real variation.
      expect(variation_ids).to include(store.get(store_key)["bucketing"][exp_id])
    end
  end
end
