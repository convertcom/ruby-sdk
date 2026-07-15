# frozen_string_literal: true

require "spec_helper"

# qs-03 (RB-6, FINAL task) — the zero-trace hard requirement on a preview-active
# Context: ALL tracking (bucketing + conversion enqueue) and ALL visitor-state
# persistence writes disabled for the ENTIRE context lifecycle, while every
# OTHER (non-target) experience on that same context keeps deciding normally.
#
# Spec of record: _bmad-output/planning-artifacts/2026-06-05-convert-ruby-sdk/
#   qs-03-experiment-preview.md
#   - AC3 (token/preview hygiene: no trace of the forced pick reaches tracking)
#   - AC6 (zero trace across the FULL lifecycle, including the at_exit flush)
#   - AC7 (isolation: a concurrent NON-preview context tracks/persists normally)
#
# JS oracles (javascript-sdk, branch feat/experiment-preview):
#   - SDK-5 (c0b89f1) introduces `enableTracking`/`enableStorage` on OTHER
#     experiences + the `trackConversion` no-op short-circuit.
#   - SDK-6 (163d403) closes the storage hole SDK-5 left open: segments writes
#     (`setDefaultSegments`/`runCustomSegments`/`updateVisitorProperties`) are
#     ALSO guarded on `_preview`.
#
# Already GREEN on this branch (RB-5, spec/unit/context_preview_spec.rb):
#   - Context#set_preview + the forced-decision short-circuit in #run_experience
#     for the TARGET experience (no enqueue, no BUCKETING event, no persist —
#     the forced branch never calls #fire_bucketing at all).
#
# NOT YET implemented (this file pins the RED): on a preview-active Context,
# OTHER (non-target) experiences still decide correctly today, but their
# bucketing enqueue AND sticky-bucketing persist still fire exactly as if no
# preview were active; #track_conversion still enqueues + marks dedup; the
# three segments write sites still persist. Every method under test here
# ALREADY EXISTS (RB-5 shipped it) — these examples must fail on ASSERTION
# (a write/enqueue that should be absent is present), never on NoMethodError
# or a setup/fixture error.
#
# Fixture vector (spec/fixtures/test-config.json, pinned — not luck):
#   - TARGET: "test-experience-ab-fullstack-2" (id 100218245), forced variation
#     100299456 — identical to RB-5's context_preview_spec.rb fixture.
#   - OTHER: "test-experience-ab-fullstack-3" (id 100218246) — shares the same
#     transient audience as the target (matching_attrs below satisfies both),
#     two running variations at 50/50 traffic (full coverage — every visitor
#     buckets, never a miss). visitor-1 deterministically buckets into
#     variation 100299461 (the SAME pinned vector spec/integration/
#     full_chain_spec.rb proves for run_feature's cross-experience carrier).
#   - GOAL_KEY "goal-without-rule" / SEGMENT_KEY "test-segments-1" (id
#     200299434, matches ruleData {"enabled"=>true}) are the SAME pinned
#     full_chain_spec.rb vectors — that spec is the live proof these writes
#     DO happen on a normal (non-preview) context, so a preview context
#     writing nothing here is a real suppression, not an accidental miss.
#
# GREEN implementation seams flagged (not decided here — tests are
# implementation-agnostic, asserting only through the public Context API):
#   - Thread an `enable_storage:`-shaped flag (derived from `@preview.nil?`)
#     through Context#decision_attributes -> ExperienceManager -> DataManager
#     #get_bucketing -> #persist_bucketing, gating that write.
#   - Suppress the OTHER-experience bucketing ENQUEUE the same way #run_experience
#     already suppresses it for `enable_tracking: false` (Story 4.5) — e.g.
#     `track: @preview.nil? && tracking_enabled_for_call?(attributes)`.
#   - #track_conversion needs an early `return self if @preview` mirroring the
#     existing `unless @config.tracking` guard (context.rb:497), BEFORE
#     DataManager#convert's dedup mark.
#   - #update_visitor_properties needs to skip ONLY the
#     `@data_store_manager.merge_visitor_data` call under preview (the
#     in-memory `@attributes` merge stays — "per-context scratch" per the spec).
#   - #set_default_segments / #run_custom_segments need their persistence write
#     suppressed under preview — either an early Context-level guard, or (JS
#     parity) an `enable_storage:` flag threaded into SegmentsManager#put_segments
#     / #select_custom_segments. Left open for GREEN to decide.
#   - NOT tested here (surfaced, not enforced): the JS oracle (SDK-5) ALSO wraps
#     the SystemEvents::BUCKETING lifecycle-event fire for OTHER experiences in
#     `if (!this._preview)`. The existing Ruby architecture (context.rb's
#     #fire_bucketing doc, Story 4.5) states the BUCKETING lifecycle event
#     ALWAYS fires regardless of the tracking gate ("decisioning observability,
#     not tracking"). This file does NOT assert either way for OTHER
#     experiences under preview — a real JS/Ruby divergence candidate to
#     surface to the user during GREEN, not to silently resolve here.
module ZeroTraceVector
  TARGET_EXP_KEY = "test-experience-ab-fullstack-2"
  TARGET_EXP_ID = "100218245"
  TARGET_FORCED_VARIATION_ID = "100299456"
  OTHER_EXP_KEY = "test-experience-ab-fullstack-3"
  OTHER_EXP_ID = "100218246"
  OTHER_VARIATION_ID = "100299461" # pinned deterministic bucket for visitor-1
  GOAL_KEY = "goal-without-rule"
  SEGMENT_KEY = "test-segments-1"
  SDK_KEY = "sdk-key-1"
  # feature-1 is carried by BOTH the TARGET and OTHER experiences — the SAME
  # pinned vector spec/integration/full_chain_spec.rb proves resolves to two
  # ENABLED BucketedFeatures for visitor-1 under matching_attrs (FIX-2, review
  # round 1). Reused here so run_feature/run_features resolve a REAL enabled
  # feature on a preview context, proving the suppressed persist is a genuine
  # suppression rather than a trivial absence.
  FEATURE_KEY = "feature-1"
  # visitor-1's natural (unforced) bucket for the TARGET experience — preview's
  # forced short-circuit lives ONLY in #run_experience (context.rb, the
  # `key == preview[:experience_key]` check), so feature resolution (which
  # calls DataManager#get_bucketing directly, never through that check)
  # decides the TARGET experience normally even on a preview context. Same
  # pinned vector as full_chain_spec.rb's VAR_ID.
  TARGET_NATURAL_VARIATION_ID = "100299457"
end

# Table for the segments-write-suppression group (AC6): three independent
# public-API call shapes, each proven (via full_chain_spec.rb) to persist on a
# NORMAL context, asserted here to persist NOTHING on a preview context.
ZERO_TRACE_SEGMENTS_WRITE_TABLE = [
  {
    label: "update_visitor_properties",
    action: ->(ctx) { ctx.update_visitor_properties({ "custom_scratch" => "value" }) }
  },
  {
    label: "set_default_segments",
    action: ->(ctx) { ctx.set_default_segments({ "country" => "US" }) }
  },
  {
    label: "run_custom_segments (the segment would otherwise match and attach)",
    action: lambda { |ctx|
      ctx.run_custom_segments([ZeroTraceVector::SEGMENT_KEY], { ruleData: { "enabled" => true } })
    }
  }
].freeze

# Table for the feature-resolution-still-decides-but-zero-trace group (AC6):
# run_feature and run_features both resolve THROUGH FeatureManager ->
# DataManager#get_bucketing (feature_manager.rb), never through
# Context#run_experience's forced short-circuit, so this table proves the SAME
# decision_attributes seam (enable_storage: @preview.nil?) suppresses
# persistence for feature resolution too — not just experience decisioning.
ZERO_TRACE_FEATURE_RESOLUTION_TABLE = [
  {
    label: "run_feature",
    resolve: ->(ctx) { Array(ctx.run_feature(ZeroTraceVector::FEATURE_KEY)) }
  },
  {
    label: "run_features",
    resolve: lambda { |ctx|
      ctx.run_features.select do |f|
        f.key == ZeroTraceVector::FEATURE_KEY && f.status == ConvertSdk::FeatureStatus::ENABLED
      end
    }
  }
].freeze

RSpec.describe "Context zero-trace suppression on a preview-active Context (RB-6 / qs-03 AC3, AC6, AC7)" do
  ZeroTraceVector.constants.each do |const|
    define_method(const.to_s.downcase) { ZeroTraceVector.const_get(const) }
  end

  let(:sink) { CapturingSink.new }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:matching_attrs) { { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" } }
  let(:track_url) { "#{HttpStubs::TRACK_HOST}/#{ConfigFixture.project_id}/v1/track/#{sdk_key}" }

  # Process-wide get_config_by_experience memo (RB-3 AC8) — reset around every
  # example so no example's target/other resolution is served from another's
  # memo (same precedent as context_preview_spec.rb).
  before do
    if ConvertSdk::ApiManager.respond_to?(:reset_config_by_experience_cache_for_tests!)
      ConvertSdk::ApiManager.reset_config_by_experience_cache_for_tests!
    end
  end

  # Build a fully-wired Client through the real public factory (ConvertSdk.create)
  # — direct-data mode (no config fetch), timer-off on both timers (deterministic;
  # explicit flush only, NFR4-safe), pointed at the WebMock track host. The track
  # POST is stubbed to succeed so a NON-preview context's flush (AC7) delivers
  # cleanly; the whole point of the zero-trace assertions below is that the
  # PREVIEW context's activity never reaches this stub at all.
  def build_client
    stub_request(:post, track_url)
      .with(&capture).to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
    ConvertSdk.create(
      data: ConfigFixture.config, sdk_key: sdk_key,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      store: store, sink: sink, flush_interval: nil, data_refresh_interval: nil
    )
  end

  # The visitor store key (DataStoreManager's byte-identical builder), read
  # straight off the account/project the client actually installed — no
  # separate DataStoreManager instance needed, {Client} does not expose one.
  def visitor_key(client, visitor_id)
    "#{client.data_manager.account_id}-#{client.data_manager.project_id}-#{visitor_id}"
  end

  # This visitor's persisted StoreData, or nil when nothing was ever written —
  # the single assertion point every zero-trace example below reads.
  def stored_data_for(client, visitor_id)
    store.get(visitor_key(client, visitor_id))
  end

  # Build a Context already forced into preview for the TARGET experience.
  def preview_context(client, visitor_id, attributes = matching_attrs)
    ctx = client.create_context(visitor_id, attributes)
    ctx.set_preview(experience_id: target_exp_id, variation_id: target_forced_variation_id)
    ctx
  end

  describe "AC6 — full preview-context lifecycle leaves zero trace" do
    it "produces zero track POSTs and zero visitor-state writes across decide, convert, flush, and at_exit" do
      client = build_client
      visitor_id = "preview-visitor-lifecycle"
      ctx = preview_context(client, visitor_id)

      ctx.run_experience(target_exp_key) # the forced target (already GREEN, RB-5)
      ctx.run_experience(other_exp_key)  # an OTHER experience — decides, must not track/persist
      ctx.track_conversion(goal_key, goal_data: { amount: 9.99 })
      client.flush("manual")
      client.send(:run_at_exit_flush) # the at_exit handler body (Story 4.4) — nothing to send

      expect(a_request(:post, track_url)).not_to have_been_made
      expect(client.api_manager.queue.size).to eq(0)
      expect(stored_data_for(client, visitor_id)).to be_nil
    end
  end

  describe "OTHER (non-target) experiences on a preview context" do
    it "still decide correctly but enqueue no bucketing event and persist no sticky bucketing" do
      client = build_client
      ctx = preview_context(client, "visitor-1")

      result = ctx.run_experience(other_exp_key)

      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(result.id).to eq(other_variation_id) # decisioning is NOT disabled
      expect(client.api_manager.queue.size).to eq(0) # bucketing enqueue suppressed
      expect(stored_data_for(client, "visitor-1")).to be_nil # sticky persist suppressed
    end
  end

  describe "run_experiences on a preview context (plural decisioning surface)" do
    it "decides other experiences normally but enqueues nothing and persists no sticky bucketing" do
      client = build_client
      ctx = preview_context(client, "visitor-1")

      results = ctx.run_experiences
      other = results.find { |v| v.experience_id == other_exp_id }

      expect(other).to be_a(ConvertSdk::BucketedVariation) # decisioning is NOT disabled
      expect(other.id).to eq(other_variation_id)
      expect(client.api_manager.queue.size).to eq(0) # bucketing enqueue suppressed for every decided variation
      expect(stored_data_for(client, "visitor-1")).to be_nil # sticky persist suppressed for every decided variation
    end
  end

  describe "#track_conversion is a full no-op on a preview context" do
    it "enqueues nothing, fires no CONVERSION event, marks no dedup, and returns self" do
      client = build_client
      visitor_id = "preview-visitor-convert"
      fired = []
      client.on(ConvertSdk::SystemEvents::CONVERSION) { |payload, _err| fired << payload }
      ctx = preview_context(client, visitor_id)

      result = ctx.track_conversion(goal_key, goal_data: { amount: 1.0 })

      expect(result).to be(ctx)
      expect(client.api_manager.queue.size).to eq(0)
      expect(fired).to be_empty

      # No dedup mark was left behind: a LATER, non-preview context for the
      # SAME visitor/goal still converts (the goal is not already "used up").
      non_preview_ctx = client.create_context(visitor_id, matching_attrs)
      non_preview_ctx.track_conversion(goal_key, goal_data: { amount: 1.0 })
      expect(client.api_manager.queue.size).to eq(1)
    end
  end

  describe "segments writes suppressed on a preview context" do
    ZERO_TRACE_SEGMENTS_WRITE_TABLE.each do |row|
      it "#{row[:label]} writes nothing to the store" do
        client = build_client
        visitor_id = "preview-visitor-segments-#{row[:label].gsub(/[^a-z0-9]+/i, "-")}"
        ctx = preview_context(client, visitor_id)

        expect { row[:action].call(ctx) }.not_to raise_error

        expect(stored_data_for(client, visitor_id)).to be_nil
      end
    end

    it "still updates update_visitor_properties' in-memory scratch (only the STORE write is suppressed)" do
      client = build_client
      ctx = preview_context(client, "preview-visitor-scratch")

      ctx.update_visitor_properties({ "custom_scratch" => "value" })

      expect(ctx.attributes["custom_scratch"]).to eq("value")
      expect(stored_data_for(client, "preview-visitor-scratch")).to be_nil
    end
  end

  describe "run_feature/run_features resolve a real carried feature on a preview context" do
    ZERO_TRACE_FEATURE_RESOLUTION_TABLE.each do |row|
      it "#{row[:label]} resolves feature-1 as ENABLED across both carrying experiences, zero trace" do
        client = build_client
        ctx = preview_context(client, "visitor-1")

        enabled = row[:resolve].call(ctx)
        by_exp = enabled.to_h { |f| [f.experience_id, f] }

        # A real decision, not a trivial miss — both carrying experiences
        # resolved (same pinned vector as full_chain_spec.rb's feature-1
        # assertion), so the store/queue assertions below prove a genuine
        # suppression rather than an accidental miss.
        expect(enabled.size).to eq(2)
        expect(by_exp[target_exp_id].variables["caption"]).to eq("Not allowed")
        expect(by_exp[other_exp_id].variables["caption"]).to eq("Allowed")

        expect(client.api_manager.queue.size).to eq(0)
        expect(stored_data_for(client, "visitor-1")).to be_nil
      end

      it "#{row[:label]} DOES persist sticky bucketing on a NON-preview context (isolation cross-check)" do
        client = build_client
        ctx = client.create_context("visitor-1", matching_attrs)

        enabled = row[:resolve].call(ctx)

        expect(enabled.size).to eq(2) # same real decision as the preview case above
        stored = stored_data_for(client, "visitor-1")
        expect(stored).not_to be_nil
        expect(stored["bucketing"][target_exp_id]).to eq(target_natural_variation_id)
        expect(stored["bucketing"][other_exp_id]).to eq(other_variation_id)
      end
    end
  end

  describe "AC7 — a concurrent non-preview context on the same client is unaffected" do
    it "buckets, persists sticky bucketing, and enqueues a bucketing event exactly as if no preview context existed" do
      client = build_client
      preview_ctx = preview_context(client, "preview-visitor-isolation")
      preview_ctx.run_experience(other_exp_key) # preview activity FIRST — must not bleed into the context below

      normal_ctx = client.create_context("normal-visitor-isolation", matching_attrs)
      result = normal_ctx.run_experience(other_exp_key)

      expect(result).to be_a(ConvertSdk::BucketedVariation)
      stored = stored_data_for(client, "normal-visitor-isolation")
      expect(stored).not_to be_nil
      expect(stored["bucketing"][other_exp_id]).to eq(result.id)
      expect(client.api_manager.queue.size).to eq(1)

      drained = client.api_manager.queue.drain!
      expect(drained.first["visitorId"]).to eq("normal-visitor-isolation")

      # The preview context's own activity is STILL trace-free, even after the
      # concurrent normal context's write landed.
      expect(stored_data_for(client, "preview-visitor-isolation")).to be_nil
    end
  end
end
