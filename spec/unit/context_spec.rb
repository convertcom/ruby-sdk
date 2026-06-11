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
  let(:feature_manager) { ConvertSdk::FeatureManager.new(data_manager: data_manager, log_manager: log_manager) }
  let(:segments_manager) do
    ConvertSdk::SegmentsManager.new(
      data_manager: data_manager, data_store_manager: data_store_manager,
      account_resolver: -> { ConfigFixture.account_id },
      project_resolver: -> { ConfigFixture.project_id },
      rule_manager: rule_manager, log_manager: log_manager
    )
  end

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

  # The default wired collaborators — a single source merged with per-example
  # +overrides+ so one example can swap one collaborator for a raising double.
  def default_collaborators
    {
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: experience_manager, feature_manager: feature_manager,
      segments_manager: segments_manager
    }
  end

  # Build a Context through the real constructor with the wired collaborators.
  def build_context(visitor_id: "visitor-1", attributes: nil, **overrides)
    described_class.new(
      visitor_id: visitor_id, attributes: attributes,
      **default_collaborators.merge(overrides)
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

  describe "#run_feature (Story 3.1 — AC#1,#3,#4,#5)" do
    # visitor-1 + these attributes buckets into fullstack-2 (var 100299457) AND
    # fullstack-3 (var 100299461), both carrying feature-1 (10024). feature-2
    # (10025) is carried by no bucketed variation. Verified against the fixture.
    let(:matching) { { "varName1" => "value1", "varName2" => "value2" } }

    def ctx(attributes: nil)
      build_context(visitor_id: "visitor-1", attributes: attributes)
    end

    it "returns ENABLED feature(s) for a feature carried by the visitor's bucketed variation(s)" do
      result = ctx(attributes: matching.merge("environment" => "staging")).run_feature("feature-1")
      # feature-1 sits in TWO bucketed variations -> an Array of ENABLED features.
      features = Array(result)
      expect(features).to all(be_a(ConvertSdk::BucketedFeature))
      expect(features).to all(have_attributes(status: ConvertSdk::FeatureStatus::ENABLED))
      expect(features.map(&:key).uniq).to eq(["feature-1"])
    end

    it "merges per-call attributes over context attributes (deep-stringified)" do
      result = ctx(attributes: { "environment" => "staging" })
               .run_feature("feature-1", varName1: "value1", varName2: "value2")
      expect(Array(result)).to all(have_attributes(status: ConvertSdk::FeatureStatus::ENABLED))
    end

    it "returns a DISABLED BucketedFeature (declared, not bucketed) with a debug log on a miss" do
      result = ctx(attributes: { "environment" => "staging" })
               .run_feature("feature-1", varName1: "no", varName2: "no")
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.key).to eq("feature-1")
    end

    it "returns a DISABLED BucketedFeature (key only) for an undeclared feature" do
      result = ctx(attributes: matching.merge("environment" => "staging")).run_feature("no-such-feature")
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.key).to eq("no-such-feature")
      expect(result.id).to be_nil
    end

    it "never raises — a raising feature_manager degrades to a DISABLED feature + error log" do
      raising = instance_double(ConvertSdk::FeatureManager)
      allow(raising).to receive(:run_feature).and_raise(StandardError, "boom")
      c = build_context(attributes: { "environment" => "staging" }, feature_manager: raising)
      result = nil
      expect { result = c.run_feature("feature-1") }.not_to raise_error
      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(sink.joined).to include("Context#run_feature")
    end

    it "performs ZERO HTTP on the cached-config evaluation (NFR1)" do
      ctx(attributes: matching.merge("environment" => "staging")).run_feature("feature-1")
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "#run_features (Story 3.1 — AC#2,#4,#5)" do
    let(:matching) { { "varName1" => "value1", "varName2" => "value2" } }

    def ctx(attributes: nil)
      build_context(visitor_id: "visitor-1", attributes: attributes)
    end

    it "returns every declared feature (ENABLED for carried, DISABLED otherwise)" do
      results = ctx(attributes: matching.merge("environment" => "staging")).run_features
      expect(results).to all(be_a(ConvertSdk::BucketedFeature))
      statuses = results.group_by(&:key).transform_values { |fs| fs.map(&:status).uniq }
      expect(statuses["feature-1"]).to include(ConvertSdk::FeatureStatus::ENABLED)
      expect(statuses["feature-2"]).to eq([ConvertSdk::FeatureStatus::DISABLED])
    end

    it "returns all DISABLED when the visitor is bucketed nowhere" do
      results = ctx(attributes: { "environment" => "staging" }).run_features(varName1: "no", varName2: "no")
      expect(results).to all(have_attributes(status: ConvertSdk::FeatureStatus::DISABLED))
    end

    it "never raises — a raising feature_manager degrades to an empty list + error log" do
      raising = instance_double(ConvertSdk::FeatureManager)
      allow(raising).to receive(:run_features).and_raise(StandardError, "boom")
      c = build_context(attributes: { "environment" => "staging" }, feature_manager: raising)
      result = nil
      expect { result = c.run_features }.not_to raise_error
      expect(result).to eq([])
      expect(sink.joined).to include("Context#run_features")
    end

    it "performs ZERO HTTP on the cached-config evaluation (NFR1)" do
      ctx(attributes: matching.merge("environment" => "staging")).run_features
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "#set_default_segments (Story 3.2 — AC#1)" do
    def stored_segments(visitor_id)
      build_context(visitor_id: visitor_id).get_visitor_data["segments"]
    end

    it "persists report-segments into the visitor's StoreData (deep-stringified)" do
      build_context(visitor_id: "v-seg").set_default_segments(visitorType: "new", country: "US")
      expect(stored_segments("v-seg")).to eq("visitorType" => "new", "country" => "US")
    end

    it "drops non-report keys before persisting (report-segment filter)" do
      build_context(visitor_id: "v-seg2").set_default_segments(country: "US", plan: "pro")
      expect(stored_segments("v-seg2")).to eq("country" => "US")
    end

    it "returns self (chainable)" do
      ctx = build_context(visitor_id: "v-chain")
      expect(ctx.set_default_segments(country: "US")).to be(ctx)
    end

    it "never crashes — a raising segments_manager degrades to self + error log" do
      raising = instance_double(ConvertSdk::SegmentsManager)
      allow(raising).to receive(:put_segments).and_raise(StandardError, "boom")
      ctx = build_context(segments_manager: raising)
      result = nil
      expect { result = ctx.set_default_segments(country: "US") }.not_to raise_error
      expect(result).to be(ctx)
      expect(sink.joined).to include("Context#set_default_segments")
    end
  end

  describe "#run_custom_segments (Story 3.2 — AC#2,#4)" do
    def stored_segments(visitor_id)
      build_context(visitor_id: visitor_id).get_visitor_data["segments"]
    end

    it "attaches matching custom segment ids under customSegments" do
      build_context(visitor_id: "v-cs").run_custom_segments(["test-segments-1"], ruleData: { enabled: true })
      expect(stored_segments("v-cs")).to eq("customSegments" => ["200299434"])
    end

    it "does not attach when the segment rules do not match" do
      build_context(visitor_id: "v-cs2").run_custom_segments(["test-segments-1"], ruleData: { enabled: false })
      expect(stored_segments("v-cs2")).to eq({})
    end

    it "evaluates against stored segments merged with per-call ruleData (JS getVisitorProperties)" do
      ctx = build_context(visitor_id: "v-cs3", attributes: { enabled: true })
      ctx.run_custom_segments(["test-segments-1"])
      expect(stored_segments("v-cs3")).to eq("customSegments" => ["200299434"])
    end

    it "returns nil on a match (no RuleError)" do
      result = build_context(visitor_id: "v-cs4")
               .run_custom_segments(["test-segments-1"], ruleData: { enabled: true })
      expect(result).to be_nil
    end

    it "skips an unknown segment key (debug log, never raises)" do
      ctx = build_context(visitor_id: "v-cs5")
      result = nil
      expect { result = ctx.run_custom_segments(["no-such-segment"], ruleData: { enabled: true }) }
        .not_to raise_error
      expect(result).to be_nil
      expect(stored_segments("v-cs5")).to eq({})
    end

    it "never crashes — a raising segments_manager degrades to nil + error log" do
      raising = instance_double(ConvertSdk::SegmentsManager)
      allow(raising).to receive(:select_custom_segments).and_raise(StandardError, "boom")
      ctx = build_context(visitor_id: "v-cs6", segments_manager: raising)
      result = :sentinel
      expect { result = ctx.run_custom_segments(["test-segments-1"]) }.not_to raise_error
      expect(result).to be_nil
      expect(sink.joined).to include("Context#run_custom_segments")
    end

    it "does NOT fire SystemEvents::SEGMENTS on attachment (JS parity, F-014)" do
      fired = []
      event_manager.on(ConvertSdk::SystemEvents::SEGMENTS) { |payload, _err| fired << payload }
      build_context(visitor_id: "v-cs7").run_custom_segments(["test-segments-1"], ruleData: { enabled: true })
      expect(fired).to be_empty
    end
  end

  # --- Story 4.3: track_conversion (conversion + revenue + dedup) -----------

  describe "#track_conversion (AC#1-4)" do
    let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }
    # A real ApiManager (timer-off so no background flush during the example);
    # the enqueued event is inspected by draining the underlying queue.
    let(:api_manager) do
      cfg = ConvertSdk::Config.new(
        data: ConfigFixture.config, sdk_key: "sdk-key-1",
        track_endpoint: "https://track.example.test/[project_id]/v1",
        flush_interval: nil, log_manager: log_manager
      )
      ConvertSdk::ApiManager.new(
        config: cfg, data_manager: data_manager, http_client: http_client,
        event_manager: event_manager, log_manager: log_manager
      )
    end

    let(:goal_key) { "increase-engagement" }
    let(:goal_id) { "100215960" }

    def conv_context(visitor_id: "visitor-conv")
      build_context(visitor_id: visitor_id, api_manager: api_manager)
    end

    # The single drained conversion event (or nil when the queue is empty).
    def drained_conversion_event
      visitors = api_manager.queue.drain!
      events = visitors.flat_map { |v| v["events"] }
      events.find { |e| e["eventType"] == "conversion" }
    end

    describe "enqueued conversion event shape (AC#1, #4)" do
      it "enqueues a wire-shaped conversion event with goalId" do
        conv_context.track_conversion(goal_key)
        event = drained_conversion_event
        expect(event["eventType"]).to eq("conversion")
        expect(event["data"]["goalId"]).to eq(goal_id)
      end

      it "carries goalData as [{key,value}] pairs (golden, field-by-field)" do
        conv_context.track_conversion(goal_key, goal_data: { amount: 49.99, transaction_id: "tx-9" })
        event = drained_conversion_event
        expect(event).to eq(
          "eventType" => "conversion",
          "data" => {
            "goalId" => goal_id,
            "goalData" => [
              { "key" => "amount", "value" => 49.99 },
              { "key" => "transactionId", "value" => "tx-9" }
            ]
          }
        )
      end

      it "omits goalData when no revenue data is supplied" do
        conv_context.track_conversion(goal_key)
        expect(drained_conversion_event["data"]).not_to have_key("goalData")
      end

      it "includes bucketingData from the visitor's stored bucketing map" do
        data_store_manager.merge_visitor_data(
          ConfigFixture.account_id, ConfigFixture.project_id, "vis-bkt"
        ) { |_c| { "bucketing" => { "100" => "200" } } }
        conv_context(visitor_id: "vis-bkt").track_conversion(goal_key)
        expect(drained_conversion_event["data"]["bucketingData"]).to eq({ "100" => "200" })
      end

      it "omits bucketingData for an unbucketed visitor (JS parity)" do
        conv_context.track_conversion(goal_key)
        expect(drained_conversion_event["data"]).not_to have_key("bucketingData")
      end
    end

    describe "dedup (AC#2) + force (AC#3) through the public surface" do
      it "enqueues only ONE conversion across two non-forced tracks for the same goal" do
        ctx = conv_context
        ctx.track_conversion(goal_key)
        ctx.track_conversion(goal_key)
        visitors = api_manager.queue.drain!
        conversions = visitors.flat_map { |v| v["events"] }.select { |e| e["eventType"] == "conversion" }
        expect(conversions.size).to eq(1)
      end

      it "enqueues a second conversion when force_multiple_transactions is true" do
        ctx = conv_context
        ctx.track_conversion(goal_key)
        ctx.track_conversion(goal_key, force_multiple_transactions: true)
        visitors = api_manager.queue.drain!
        conversions = visitors.flat_map { |v| v["events"] }.select { |e| e["eventType"] == "conversion" }
        expect(conversions.size).to eq(2)
      end

      it "does not enqueue on an unknown goal key" do
        conv_context.track_conversion("no-such-goal")
        expect(drained_conversion_event).to be_nil
      end
    end

    describe "CONVERSION system event (AC#4)" do
      it "fires SystemEvents::CONVERSION on a successful track" do
        fired = []
        event_manager.on(ConvertSdk::SystemEvents::CONVERSION) { |payload, _err| fired << payload }
        conv_context.track_conversion(goal_key)
        expect(fired.size).to eq(1)
        expect(fired.first).to include(visitor_id: "visitor-conv", goal_key: goal_key)
      end

      it "fires deferred so a LATE subscriber still receives the replay (deferred: true)" do
        conv_context(visitor_id: "v-late").track_conversion(goal_key)
        replayed = []
        # Subscribing AFTER the fire must still deliver the conversion payload.
        event_manager.on(ConvertSdk::SystemEvents::CONVERSION) { |payload, _err| replayed << payload }
        expect(replayed.size).to eq(1)
        expect(replayed.first).to include(visitor_id: "v-late", goal_key: goal_key)
      end

      it "fires CONVERSION only on the successful track, not on the deduplicated repeat" do
        fired = []
        # Subscribed BEFORE any track → counts live fires (not deferred replays).
        event_manager.on(ConvertSdk::SystemEvents::CONVERSION) { |payload, _err| fired << payload }
        ctx = conv_context
        ctx.track_conversion(goal_key) # success → fires
        ctx.track_conversion(goal_key) # deduplicated → no fire
        expect(fired.size).to eq(1)
      end
    end

    describe "never-crash boundary (NFR9)" do
      it "returns self and error-logs when a collaborator raises" do
        raising = instance_double(ConvertSdk::DataManager)
        allow(raising).to receive(:ensure_fresh_config!).and_raise(StandardError, "boom")
        ctx = build_context(api_manager: api_manager, data_manager: raising)
        result = nil
        expect { result = ctx.track_conversion(goal_key) }.not_to raise_error
        expect(result).to eq(ctx)
        expect(sink.joined).to include("Context#track_conversion")
      end
    end
  end
end
