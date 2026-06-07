# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Context do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }
  let(:experience_manager) { ConvertSdk::ExperienceManager.new(data_manager: data_manager, log_manager: log_manager) }

  # A DataManager loaded with the vendored fixture (direct-data install) so the
  # config readers behind get_config_entity return real entities. Wired with the
  # decisioning collaborators so run_experience(s) can decide (Story 2.11).
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

  # Recursively stringify keys — DataManager#install_config expects the
  # string-keyed wire shape (the Client normalises at its boundary).
  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # Build a Context through the real constructor with the wired collaborators.
  # +overrides+ lets a single example swap one collaborator for a raising double.
  def build_context(visitor_id: "visitor-1", attributes: nil, **overrides)
    described_class.new(
      visitor_id: visitor_id,
      attributes: attributes,
      data_manager: overrides.fetch(:data_manager, data_manager),
      data_store_manager: overrides.fetch(:data_store_manager, data_store_manager),
      event_manager: overrides.fetch(:event_manager, event_manager),
      log_manager: overrides.fetch(:log_manager, log_manager),
      config: overrides.fetch(:config, config),
      experience_manager: overrides.fetch(:experience_manager, experience_manager)
    )
  end

  describe "construction + attribute normalisation (AC#1)" do
    it "holds the visitor id" do
      expect(build_context(visitor_id: "abc").visitor_id).to eq("abc")
    end

    it "defaults to empty attributes when none are supplied" do
      expect(build_context(attributes: nil).attributes).to eq({})
    end

    # Symbol, string, mixed, nested-hash, and array-of-hashes inputs must all
    # normalise to the SAME string-keyed shape (deep-stringify at the boundary).
    [
      ["symbol keys", { country: "US" }, { "country" => "US" }],
      ["string keys", { "country" => "US" }, { "country" => "US" }],
      ["mixed keys", { :country => "US", "browser" => "chrome" },
       { "country" => "US", "browser" => "chrome" }],
      ["nested hash", { geo: { country: "US", city: "NYC" } },
       { "geo" => { "country" => "US", "city" => "NYC" } }],
      ["array of hashes", { tags: [{ k: "a" }, { k: "b" }] },
       { "tags" => [{ "k" => "a" }, { "k" => "b" }] }],
      ["symbol values preserved", { country: :us },
       { "country" => :us }]
    ].each do |label, input, expected|
      it "deep-stringifies #{label} at the public boundary" do
        expect(build_context(attributes: input).attributes).to eq(expected)
      end
    end

    it "treats symbol- and string-keyed inputs as equivalent" do
      sym = build_context(attributes: { country: "US" }).attributes
      str = build_context(attributes: { "country" => "US" }).attributes
      expect(sym).to eq(str)
    end

    it "does not mutate the caller's attribute hash" do
      original = { country: "US" }
      build_context(attributes: original)
      expect(original).to eq({ country: "US" })
    end
  end

  describe "#update_visitor_properties (AC#3)" do
    let(:account_id) { ConfigFixture.account_id }
    let(:project_id) { ConfigFixture.project_id }
    let(:store_key) { data_store_manager.visitor_key(account_id, project_id, "visitor-1") }

    it "persists properties under the StoreData segments sub-key via the store" do
      build_context.update_visitor_properties(plan: "pro")
      stored = data_store_manager.get(store_key)
      expect(stored["segments"]).to eq({ "plan" => "pro" })
    end

    it "deep-stringifies symbol keys before persisting" do
      build_context.update_visitor_properties(geo: { country: :us })
      stored = data_store_manager.get(store_key)
      expect(stored["segments"]).to eq({ "geo" => { "country" => :us } })
    end

    it "merges into in-memory attributes so subsequent decisions see the merge" do
      ctx = build_context(attributes: { country: "US" })
      ctx.update_visitor_properties(plan: "pro")
      expect(ctx.attributes).to eq({ "country" => "US", "plan" => "pro" })
    end

    it "merges (not replaces) across multiple property updates in the store" do
      ctx = build_context
      ctx.update_visitor_properties(plan: "pro")
      ctx.update_visitor_properties(tier: "gold")
      stored = data_store_manager.get(store_key)
      expect(stored["segments"]).to eq({ "plan" => "pro", "tier" => "gold" })
    end

    it "returns self for chaining" do
      ctx = build_context
      expect(ctx.update_visitor_properties(plan: "pro")).to be(ctx)
    end
  end

  describe "multi-context independence (AC#2)" do
    it "keeps in-memory attributes independent across different visitor ids" do
      a = build_context(visitor_id: "v-a", attributes: { country: "US" })
      b = build_context(visitor_id: "v-b", attributes: { country: "CA" })
      a.update_visitor_properties(plan: "pro")
      expect(a.attributes).to eq({ "country" => "US", "plan" => "pro" })
      expect(b.attributes).to eq({ "country" => "CA" })
    end

    it "does not bleed stored properties between different visitor ids" do
      build_context(visitor_id: "v-a").update_visitor_properties(plan: "pro")
      key_b = data_store_manager.visitor_key(ConfigFixture.account_id, ConfigFixture.project_id, "v-b")
      expect(data_store_manager.get(key_b)).to be_nil
    end

    it "shares stored data across two contexts for the SAME visitor id (stickiness)" do
      build_context(visitor_id: "shared").update_visitor_properties(plan: "pro")
      second = build_context(visitor_id: "shared")
      expect(second.get_visitor_data["segments"]).to eq({ "plan" => "pro" })
    end
  end

  describe "#get_visitor_data (AC#4)" do
    it "returns the empty StoreData shape when the visitor has no stored data" do
      expect(build_context(visitor_id: "fresh").get_visitor_data).to eq(
        { "bucketing" => {}, "segments" => {}, "goals" => {} }
      )
    end

    it "returns the visitor's stored StoreData round-trip when present" do
      ctx = build_context(visitor_id: "v-round")
      ctx.update_visitor_properties(plan: "pro")
      expect(ctx.get_visitor_data["segments"]).to eq({ "plan" => "pro" })
    end
  end

  describe "#get_config_entity (AC#4)" do
    it "returns the experience entity for a known key" do
      entity = build_context.get_config_entity("test-experience-ab-fullstack-2", :experience)
      expect(entity["id"]).to eq("100218245")
    end

    it "returns the feature entity for a known key" do
      expect(build_context.get_config_entity("feature-1", :feature)["id"]).to eq("10024")
    end

    it "returns the goal entity for a known key" do
      expect(build_context.get_config_entity("increase-engagement", :goal)["id"]).to eq("100215960")
    end

    it "accepts a string entity_type as well as a symbol" do
      expect(build_context.get_config_entity("feature-1", "feature")["id"]).to eq("10024")
    end

    it "returns nil and debug-logs on a missing key" do
      expect(build_context.get_config_entity("no-such-key", :experience)).to be_nil
      expect(sink.joined).to include("Context#get_config_entity: no experience found for key=no-such-key")
    end

    it "returns nil and debug-logs on an unknown entity_type" do
      expect(build_context.get_config_entity("feature-1", :widget)).to be_nil
      expect(sink.joined).to include("Context#get_config_entity: no widget found for key=feature-1")
    end
  end

  describe "#run_experience (Story 2.11 — AC#1,#5,#6)" do
    let(:exp_key) { "test-experience-ab-fullstack-2" }
    let(:exp_id) { "100218245" }
    let(:variation_ids) { %w[100299456 100299457] }
    let(:matching) { { "varName1" => "value1", "varName2" => "value2" } }

    def ctx(visitor_id: "visitor-1", attributes: nil)
      build_context(visitor_id: visitor_id, attributes: attributes)
    end

    it "returns a frozen BucketedVariation for an eligible visitor" do
      result = ctx(attributes: matching.merge("environment" => "staging"))
                .run_experience(exp_key)
      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(variation_ids).to include(result.id)
    end

    it "merges per-call attributes over the context attributes (deep-stringified)" do
      # Context built WITHOUT the audience props; supplied per-call instead.
      result = ctx(attributes: { "environment" => "staging" })
               .run_experience(exp_key, varName1: "value1", varName2: "value2")
      expect(result).to be_a(ConvertSdk::BucketedVariation)
    end

    it "returns the NO_DATA_FOUND sentinel (nil key) when the audience fails" do
      result = ctx(attributes: { "environment" => "staging" })
               .run_experience(exp_key, varName1: "no", varName2: "no")
      expect(result).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
      expect(result.key).to be_nil
    end

    it "returns NO_DATA_FOUND for an unknown experience key" do
      result = ctx(attributes: { "environment" => "staging" }).run_experience("nope")
      expect(result).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end

    it "fires the BUCKETING lifecycle event on a fresh decision (AC: event seam)" do
      fired = []
      event_manager.on(ConvertSdk::SystemEvents::BUCKETING) { |payload, _err| fired << payload }
      result = ctx(attributes: matching.merge("environment" => "staging")).run_experience(exp_key)
      expect(fired.size).to eq(1)
      expect(fired.first[:experience_key]).to eq(exp_key)
      expect(fired.first[:variation_key]).to eq(result.key)
    end

    it "does NOT fire BUCKETING on a miss sentinel" do
      fired = []
      event_manager.on(ConvertSdk::SystemEvents::BUCKETING) { |payload, _err| fired << payload }
      ctx(attributes: { "environment" => "staging" }).run_experience(exp_key, varName1: "no", varName2: "no")
      expect(fired).to be_empty
    end

    it "performs ZERO HTTP on the cached-config decision path (NFR1)" do
      c = ctx(attributes: matching.merge("environment" => "staging"))
      c.run_experience(exp_key)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "never crashes — a raising experience_manager degrades to a sentinel" do
      raising = instance_double(ConvertSdk::ExperienceManager)
      allow(raising).to receive(:select_variation).and_raise(StandardError, "boom")
      c = build_context(attributes: { "environment" => "staging" }, experience_manager: raising)
      result = nil
      expect { result = c.run_experience(exp_key) }.not_to raise_error
      expect(result).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
      expect(sink.joined).to include("Context#run_experience")
    end
  end

  describe "#run_experiences (Story 2.11 — AC#2,#5)" do
    let(:matching) { { "varName1" => "value1", "varName2" => "value2" } }

    it "returns a list of frozen BucketedVariations for eligible experiences" do
      results = build_context(attributes: matching.merge("environment" => "staging")).run_experiences
      expect(results).to be_an(Array)
      expect(results).to all(be_a(ConvertSdk::BucketedVariation))
      expect(results).not_to be_empty
    end

    it "filters out misses (no sentinels in the list, JS parity)" do
      results = build_context(attributes: { "environment" => "staging" })
                .run_experiences(varName1: "no", varName2: "no")
      expect(results).to eq([])
    end

    it "merges per-call attributes over context attributes" do
      results = build_context(attributes: { "environment" => "staging" })
                .run_experiences(varName1: "value1", varName2: "value2")
      expect(results).to all(be_a(ConvertSdk::BucketedVariation))
    end

    it "fires BUCKETING once per fresh decision in the list" do
      fired = []
      event_manager.on(ConvertSdk::SystemEvents::BUCKETING) { |payload, _err| fired << payload }
      results = build_context(attributes: matching.merge("environment" => "staging")).run_experiences
      expect(fired.size).to eq(results.size)
    end

    it "never crashes — a raising experience_manager degrades to an empty list" do
      raising = instance_double(ConvertSdk::ExperienceManager)
      allow(raising).to receive(:select_variations).and_raise(StandardError, "boom")
      c = build_context(attributes: { "environment" => "staging" }, experience_manager: raising)
      result = nil
      expect { result = c.run_experiences }.not_to raise_error
      expect(result).to eq([])
      expect(sink.joined).to include("Context#run_experiences")
    end

    it "performs ZERO HTTP on the cached-config decision path (NFR1)" do
      build_context(attributes: matching.merge("environment" => "staging")).run_experiences
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "never-crash boundary (AC: all)" do
    it "update_visitor_properties returns self and logs when the store raises" do
      raising = instance_double(ConvertSdk::DataStoreManager)
      allow(raising).to receive(:merge_visitor_data).and_raise(StandardError, "boom")
      ctx = build_context(data_store_manager: raising)
      result = nil
      expect { result = ctx.update_visitor_properties(plan: "pro") }.not_to raise_error
      expect(result).to be(ctx)
      expect(sink.joined).to include("Context#update_visitor_properties")
    end

    it "get_visitor_data returns the empty shape and logs when the store raises" do
      raising = instance_double(ConvertSdk::DataStoreManager)
      allow(raising).to receive(:visitor_key).and_raise(StandardError, "boom")
      ctx = build_context(data_store_manager: raising)
      expect(ctx.get_visitor_data).to eq({ "bucketing" => {}, "segments" => {}, "goals" => {} })
      expect(sink.joined).to include("Context#get_visitor_data")
    end

    it "get_config_entity returns nil and logs when the data manager raises" do
      raising = instance_double(ConvertSdk::DataManager)
      allow(raising).to receive(:account_id).and_return("a")
      allow(raising).to receive(:project_id).and_return("p")
      allow(raising).to receive(:experience_by_key).and_raise(StandardError, "boom")
      ctx = build_context(data_manager: raising)
      expect(ctx.get_config_entity("k", :experience)).to be_nil
      expect(sink.joined).to include("Context#get_config_entity")
    end
  end
end
