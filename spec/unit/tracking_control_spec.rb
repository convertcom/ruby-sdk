# frozen_string_literal: true

require "spec_helper"

# Story 4.5: Tracking Control.
#
# The global switch (Config tracking:false) gates BOTH enqueue sites — bucketing
# (the 4.1 Context seam) and conversion (4.3) — and the per-call enable_tracking
# kwarg suppresses a single experience-running call. DECISIONING always works
# (variations returned, sticky StoreData still written); EVENTS are suppressed
# (no enqueue, no delivery, no lazy timer start). Composition: global-off ALWAYS
# wins; per-call-off under global-on suppresses only that call.
#
# Ruby enqueue topology (verified against context.rb): only run_experience /
# run_experiences enqueue (via fire_bucketing) and track_conversion enqueues a
# conversion. run_feature / run_features delegate to FeatureManager and DO NOT
# enqueue (a Ruby divergence from JS, which fires a feature BUCKETING event) — so
# the per-call enable_tracking surface is accepted on all four run methods for
# JS-parity surface consistency, but only has an observable suppression effect on
# the two experience methods. Feature calls accept it inertly.
#
# Tabular suppression matrices keep the combinatorial surface (global x per-call x
# entry-point) data-driven rather than copy-pasted.
# The two experience entry points are the only run methods that enqueue (features
# never enqueue in Ruby). Declared at file scope so the data-driven `each` blocks
# can build examples at load time.
TRACKING_ENQUEUING_ENTRY_POINTS = %i[run_experience run_experiences].freeze

RSpec.describe "Tracking control (Story 4.5)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # A Config with tracking on/off, otherwise identical (track endpoint + timer off
  # so no background flush fires during an example).
  def config_for(tracking:)
    ConvertSdk::Config.new(
      log_manager: log_manager, data: ConfigFixture.config, sdk_key: "sdk-key-1",
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      flush_interval: nil, tracking: tracking
    )
  end

  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config_for(tracking: true), log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config_for(tracking: true), log_manager: log_manager) }

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

  let(:experience_manager) { ConvertSdk::ExperienceManager.new(data_manager: data_manager, log_manager: log_manager) }
  let(:feature_manager) { ConvertSdk::FeatureManager.new(data_manager: data_manager, log_manager: log_manager) }
  let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }

  def api_manager_for(config)
    ConvertSdk::ApiManager.new(
      config: config, data_manager: data_manager, http_client: http_client,
      event_manager: event_manager, log_manager: log_manager
    )
  end

  # Build a fully-wired Context (the real bucketing/conversion enqueue seams active).
  def context(tracking:, visitor_id: "visitor-1", attributes: nil, api_manager: nil)
    config = config_for(tracking: tracking)
    ConvertSdk::Context.new(
      visitor_id: visitor_id, attributes: attributes,
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: experience_manager, feature_manager: feature_manager,
      api_manager: api_manager || api_manager_for(config)
    )
  end

  let(:exp_key) { "test-experience-ab-fullstack-2" }
  let(:feature_key) { "feature-1" }
  let(:goal_key) { "increase-engagement" }
  let(:goal_id) { "100215960" }
  let(:matching) { { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" } }

  # Run an enqueuing entry point and return [result, queue_size].
  def invoke(ctx, entry, api_manager, **per_call)
    result =
      case entry
      when :run_experience  then ctx.run_experience(exp_key, matching.merge(per_call))
      when :run_experiences then ctx.run_experiences(matching.merge(per_call))
      end
    [result, api_manager.queue.size]
  end

  describe "global switch (AC#1) — tracking:false suppresses ALL event enqueueing" do
    TRACKING_ENQUEUING_ENTRY_POINTS.each do |entry|
      it "#{entry}: returns the decision but enqueues ZERO events when tracking is off" do
        am = api_manager_for(config_for(tracking: false))
        ctx = context(tracking: false, api_manager: am)
        result, queue_size = invoke(ctx, entry, am)

        expect(result).not_to be_nil
        expect(queue_size).to eq(0)
        expect(a_request(:any, /.*/)).not_to have_been_made
      end

      it "#{entry}: still enqueues an event when tracking is on (control)" do
        am = api_manager_for(config_for(tracking: true))
        ctx = context(tracking: true, api_manager: am)
        _result, queue_size = invoke(ctx, entry, am)
        expect(queue_size).to be > 0
      end

      it "#{entry}: logs a debug suppression line when tracking is off" do
        am = api_manager_for(config_for(tracking: false))
        invoke(context(tracking: false, api_manager: am), entry, am)
        expect(sink.joined).to include("tracking disabled, event suppressed")
      end
    end

    it "run_experience: still returns a real BucketedVariation under tracking-off (decisioning intact)" do
      am = api_manager_for(config_for(tracking: false))
      result = context(tracking: false, api_manager: am).run_experience(exp_key, matching)
      expect(result).to be_a(ConvertSdk::BucketedVariation)
    end

    it "run_feature is unaffected (features never enqueue in Ruby) and returns normally under tracking-off" do
      am = api_manager_for(config_for(tracking: false))
      result = context(tracking: false, api_manager: am).run_feature(feature_key, matching)
      expect(Array(result).first).to be_a(ConvertSdk::BucketedFeature)
      expect(am.queue.size).to eq(0)
    end

    it "does NOT lazily start the flush timer when tracking is off (NFR4 bonus)" do
      am = api_manager_for(config_for(tracking: false))
      ctx = context(tracking: false, api_manager: am)
      12.times { ctx.run_experience(exp_key, matching) }
      timer = am.instance_variable_get(:@flush_timer)
      expect(timer.alive?).to be(false)
      expect(am.queue.size).to eq(0)
    end

    it "explicit flush after disable is a no-op (Ruby suppresses enqueue entirely)" do
      am = api_manager_for(config_for(tracking: false))
      context(tracking: false, api_manager: am).run_experience(exp_key, matching)
      am.release_queue("flush")
      expect(a_request(:any, /.*/)).not_to have_been_made
    end
  end

  describe "global switch — sticky StoreData write ALWAYS happens (decisioning state)" do
    it "persists bucketing StoreData under tracking-off so a later context sees stickiness" do
      am = api_manager_for(config_for(tracking: false))
      context(tracking: false, visitor_id: "sticky-vis", api_manager: am)
        .run_experience(exp_key, matching)
      stored = data_store_manager.get(
        data_store_manager.visitor_key(ConfigFixture.account_id, ConfigFixture.project_id, "sticky-vis")
      )
      expect(stored).to be_a(Hash)
      expect(stored["bucketing"]).not_to be_empty
    end
  end

  describe "track_conversion under tracking-off (AC#1)" do
    def drained_conversion_event(manager)
      manager.queue.drain!.flat_map { |v| v["events"] }.find { |e| e["eventType"] == "conversion" }
    end

    it "is a no-op at the enqueue site (zero queue, no HTTP) and returns self unchanged" do
      am = api_manager_for(config_for(tracking: false))
      ctx = context(tracking: false, visitor_id: "conv-off", api_manager: am)
      expect(ctx.track_conversion(goal_key)).to be(ctx)
      expect(am.queue.size).to eq(0)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "logs a debug suppression line" do
      am = api_manager_for(config_for(tracking: false))
      context(tracking: false, visitor_id: "conv-off2", api_manager: am).track_conversion(goal_key)
      expect(sink.joined).to include("tracking disabled, event suppressed")
    end

    it "does NOT mark dedup — re-enabling then tracking the SAME goal still enqueues" do
      am_off = api_manager_for(config_for(tracking: false))
      context(tracking: false, visitor_id: "dedup-vis", api_manager: am_off).track_conversion(goal_key)
      am_on = api_manager_for(config_for(tracking: true))
      context(tracking: true, visitor_id: "dedup-vis", api_manager: am_on).track_conversion(goal_key)
      event = drained_conversion_event(am_on)
      expect(event).not_to be_nil
      expect(event["data"]["goalId"]).to eq(goal_id)
    end

    it "enqueues normally when tracking is on (control)" do
      am = api_manager_for(config_for(tracking: true))
      context(tracking: true, visitor_id: "conv-on", api_manager: am).track_conversion(goal_key)
      expect(drained_conversion_event(am)).not_to be_nil
    end
  end

  describe "per-call enable_tracking (AC#2)" do
    TRACKING_ENQUEUING_ENTRY_POINTS.each do |entry|
      it "#{entry}: enable_tracking:false suppresses that call's enqueue (variation still returned)" do
        am = api_manager_for(config_for(tracking: true))
        ctx = context(tracking: true, api_manager: am)
        result, queue_size = invoke(ctx, entry, am, enable_tracking: false)
        expect(result).not_to be_nil
        expect(queue_size).to eq(0)
      end

      it "#{entry}: enable_tracking:true (or omitted) enqueues normally under global-on" do
        am = api_manager_for(config_for(tracking: true))
        ctx = context(tracking: true, api_manager: am)
        _result, queue_size = invoke(ctx, entry, am, enable_tracking: true)
        expect(queue_size).to be > 0
      end

      it "#{entry}: logs a debug per-call suppression line" do
        am = api_manager_for(config_for(tracking: true))
        invoke(context(tracking: true, api_manager: am), entry, am, enable_tracking: false)
        expect(sink.joined).to include("tracking suppressed for call")
      end
    end

    it "a suppressed call then an unsuppressed call: only the second enqueues" do
      am = api_manager_for(config_for(tracking: true))
      ctx = context(tracking: true, api_manager: am)
      ctx.run_experience(exp_key, matching.merge(enable_tracking: false))
      expect(am.queue.size).to eq(0)
      ctx.run_experience(exp_key, matching.merge(enable_tracking: true))
      expect(am.queue.size).to be > 0
    end

    it "accepts a string-keyed enable_tracking attribute (deep-stringify parity)" do
      am = api_manager_for(config_for(tracking: true))
      ctx = context(tracking: true, api_manager: am)
      ctx.run_experience(exp_key, matching.merge("enable_tracking" => false))
      expect(am.queue.size).to eq(0)
    end

    it "run_feature accepts enable_tracking:false inertly (features never enqueue) and returns normally" do
      am = api_manager_for(config_for(tracking: true))
      result = context(tracking: true, api_manager: am).run_feature(feature_key, matching.merge(enable_tracking: false))
      expect(Array(result).first).to be_a(ConvertSdk::BucketedFeature)
    end
  end

  describe "composition (global x per-call) — global-off ALWAYS wins" do
    # [global_tracking, per_call_enable_tracking, expect_enqueue]
    [
      [true,  nil,   true],   # both default on -> enqueue
      [true,  true,  true],   # per-call explicitly on -> enqueue
      [true,  false, false],  # per-call off under global-on -> suppressed
      [false, nil,   false],  # global off -> suppressed
      [false, true,  false],  # per-call ON cannot override global-off
      [false, false, false]   # both off -> suppressed
    ].each do |global, per_call, expect_enqueue|
      it "global=#{global}, per_call=#{per_call.inspect} -> enqueue=#{expect_enqueue}" do
        am = api_manager_for(config_for(tracking: global))
        ctx = context(tracking: global, api_manager: am)
        attrs = per_call.nil? ? matching : matching.merge(enable_tracking: per_call)
        ctx.run_experience(exp_key, attrs)
        if expect_enqueue
          expect(am.queue.size).to be > 0
        else
          expect(am.queue.size).to eq(0)
        end
      end
    end
  end
end
