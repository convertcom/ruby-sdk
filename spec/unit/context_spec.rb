# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Context do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }

  # A DataManager loaded with the vendored fixture (direct-data install) so the
  # config readers behind get_config_entity return real entities.
  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(log_manager: log_manager, data_store_manager: data_store_manager)
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
      config: overrides.fetch(:config, config)
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
