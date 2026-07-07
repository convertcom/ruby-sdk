# frozen_string_literal: true

require "spec_helper"

# qs-03 (RB-5) — Context#set_preview + the forced-decision branch of
# #run_experience.
#
# Spec of record: _bmad-output/planning-artifacts/2026-06-05-convert-ruby-sdk/
#   qs-03-experiment-preview.md
#   - AC4 (forced decision via an ?exp= fetch when the experience is absent
#     from the installed config)
#   - AC5 (full bypass / precedence over rules, bucketing, AND a differing
#     stored decision)
#   - AC7 (inert-on-bad-input + per-context isolation, including the
#     JS SDK-7 "in-place locations mutation leak on preview" guard)
#
# Zero-trace suppression (AC3/AC6 — no tracking, no visitor-state writes for
# the whole preview-context lifecycle) is a SEPARATE downstream task (RB-6)
# and is deliberately NOT asserted here.
#
# Dependencies already GREEN on this branch (read in full before writing this
# file — see their own specs for their exact contracts):
#   - DataManager#get_preview_decision (RB-4, lib/convert_sdk/data_manager.rb)
#   - ApiManager#get_config_by_experience (RB-3, lib/convert_sdk/api_manager.rb)
#
# `Context#set_preview` does not exist yet (RB-5 GREEN adds it to
# lib/convert_sdk/context.rb). Every example below must fail with a
# NoMethodError (undefined method `set_preview') — never a setup/fixture
# error — until that method exists.
#
# GAP flagged for GREEN (do not fill here): DataManager exposes
# `#experience_by_key` and `#experiences` but NO by-id reader. Resolving an
# `experience_id` against the CURRENT installed config (the in-config branch
# of AC4) therefore has no existing DataManager seam to call — GREEN must
# either add a by-id reader or linear-scan `#experiences` from Context.
CONTEXT_PREVIEW_INERT_INPUT_TABLE = [
  {
    label: "blank experience_id",
    stub_fetch: false,
    fetch_experiences: [],
    experience_id: "",
    variation_id: "100299456"
  },
  {
    label: "blank variation_id",
    stub_fetch: false,
    fetch_experiences: [],
    experience_id: "100218245",
    variation_id: ""
  },
  {
    label: "experience id unresolvable in config AND absent from the ?exp= fetch response",
    stub_fetch: true,
    fetch_experiences: [],
    experience_id: "900999",
    variation_id: "900101"
  },
  {
    label: "variation id absent from the resolved (in-config) experience",
    stub_fetch: false,
    fetch_experiences: [],
    experience_id: "100218245",
    variation_id: "does-not-exist"
  }
].freeze

RSpec.describe "Context#set_preview (RB-5 / qs-03 AC4, AC5, AC7)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }
  let(:experience_manager) { ConvertSdk::ExperienceManager.new(data_manager: data_manager, log_manager: log_manager) }
  let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }

  let(:account_id) { ConfigFixture.account_id }
  let(:project_id) { ConfigFixture.project_id }

  # Direct-data DataManager install, mirroring spec/unit/context_spec.rb's
  # exact idiom (the wired collaborators make run_experience actually decide).
  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { account_id }, project_resolver: -> { project_id }
    )
    dm.install_config(stringify(ConfigFixture.config))
    dm
  end

  # Recursively stringify keys — DataManager#install_config expects the
  # string-keyed wire shape (same helper as context_spec.rb / decision_flow_spec.rb).
  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # A real ApiManager pointed at the WebMock-stubbed config host — the ONLY
  # collaborator the ?exp= fetch branch (AC4) needs. Timer-off (flush_interval:
  # nil) so no background thread starts during the example (NFR4).
  let(:api_manager_config) do
    ConvertSdk::Config.new(
      log_manager: log_manager, data: ConfigFixture.config, sdk_key: "sdk-key-1",
      config_endpoint: HttpStubs::CONFIG_HOST,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      flush_interval: nil
    )
  end
  let(:api_manager) do
    ConvertSdk::ApiManager.new(
      config: api_manager_config, data_manager: data_manager, http_client: http_client,
      event_manager: event_manager, log_manager: log_manager
    )
  end

  # Process-wide get_config_by_experience memo (RB-3 AC8) — reset around every
  # example so no example's fetch is silently served from another's memo.
  # Guarded with respond_to? per the RB-3 spec's own precedent, so this file
  # loads cleanly even before that reset seam exists.
  before do
    if ConvertSdk::ApiManager.respond_to?(:reset_config_by_experience_cache_for_tests!)
      ConvertSdk::ApiManager.reset_config_by_experience_cache_for_tests!
    end
  end

  after do
    if ConvertSdk::ApiManager.respond_to?(:reset_config_by_experience_cache_for_tests!)
      ConvertSdk::ApiManager.reset_config_by_experience_cache_for_tests!
    end
  end

  def default_collaborators
    {
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: experience_manager, api_manager: api_manager
    }
  end

  # Build a Context through the real constructor with the wired collaborators
  # (mirrors context_spec.rb's build_context helper).
  def build_context(visitor_id: "visitor-1", attributes: nil, **overrides)
    ConvertSdk::Context.new(
      visitor_id: visitor_id, attributes: attributes,
      **default_collaborators.merge(overrides)
    )
  end

  # Stub the ?exp= config-by-experience GET (ApiManager#config_by_experience_url)
  # with a body carrying ONLY the given experiences collection, layered over the
  # vendored fixture's account/project so the response is still a valid config
  # envelope.
  def stub_config_by_experience(experiences:, sdk_key: "sdk-key-1")
    body = ConfigFixture.config.merge("experiences" => experiences)
    stub_request(:get, %r{\A#{Regexp.escape(HttpStubs::CONFIG_HOST)}/config/#{Regexp.escape(sdk_key)}(\?.*)?\z})
      .to_return(status: 200, body: JSON.generate(body), headers: json_headers)
  end

  # Every :warn-level message captured by the sink, joined (AC7 requires a
  # WARNING specifically, not just any log level, on inert bad input).
  def warn_messages
    sink.entries.select { |level, _| level == :warn }.map(&:last).join("\n")
  end

  # The fixture's real experience: id 100218245 / key
  # "test-experience-ab-fullstack-2", two running variations, gated on an
  # audience matching varName1/varName2 (verified against context_spec.rb).
  let(:exp_key) { "test-experience-ab-fullstack-2" }
  let(:exp_id) { "100218245" }
  let(:variation_ids) { %w[100299456 100299457] }
  let(:forced_variation_id) { "100299456" }
  let(:other_variation_id) { "100299457" }
  let(:matching_attrs) { { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" } }
  let(:non_matching_attrs) { { "varName1" => "no", "varName2" => "no" } }

  # A draft experience the installed config has never seen — the ?exp=-only
  # fetch target (AC4). Mirrors the RB-4 data_manager_spec.rb fixture exactly
  # so both stories pin the identical preview-experience shape.
  let(:draft_experience) do
    {
      "id" => "900001",
      "key" => "preview-exp",
      "name" => "Preview Experience",
      "status" => "draft",
      "environment" => "staging",
      "variations" => [
        {
          "id" => "900101",
          "key" => "var-a",
          "name" => "Variation A",
          "status" => "stopped",
          "traffic_allocation" => 0.0,
          "changes" => { "css" => "a" }
        }
      ]
    }
  end

  describe "in-config resolution (AC4) — experience already in the installed config" do
    it "forces the exact variation get_preview_decision would return" do
      oracle = data_manager.get_preview_decision(data_manager.experience_by_key(exp_key), forced_variation_id)
      ctx = build_context(attributes: non_matching_attrs)

      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      result = ctx.run_experience(exp_key)

      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(result.id).to eq(oracle.id)
      expect(result.key).to eq(oracle.key)
      expect(result.experience_id).to eq(oracle.experience_id)
    end

    it "bypasses the audience gate that would otherwise reject this visitor" do
      # Sanity oracle: WITHOUT preview, these non-matching attrs are a miss
      # (pinned identically in context_spec.rb's run_experience examples).
      plain_result = build_context(attributes: non_matching_attrs).run_experience(exp_key)
      expect(plain_result).to be(ConvertSdk::RuleError::NO_DATA_FOUND)

      ctx = build_context(attributes: non_matching_attrs)
      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      expect(ctx.run_experience(exp_key).id).to eq(forced_variation_id)
    end

    it "fires NO BUCKETING lifecycle event for a forced decision" do
      fired = []
      event_manager.on(ConvertSdk::SystemEvents::BUCKETING) { |payload, _err| fired << payload }
      ctx = build_context(attributes: non_matching_attrs)

      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      ctx.run_experience(exp_key)

      expect(fired).to be_empty
    end
  end

  describe "?exp=-only draft-experience resolution (AC4) — experience absent from the installed config" do
    it "fetches the draft experience via ApiManager#get_config_by_experience and forces its variation" do
      expect(data_manager.experience_by_key("preview-exp")).to be_nil # sanity: absent from config
      stub_config_by_experience(experiences: [draft_experience])
      ctx = build_context

      ctx.set_preview(experience_id: "900001", variation_id: "900101")
      result = ctx.run_experience("preview-exp")

      expect(result).to be_a(ConvertSdk::BucketedVariation)
      expect(result.id).to eq("900101")
      expect(result.experience_id).to eq("900001")
      expect(result.key).to eq("var-a")
    end

    it "performs exactly one origin fetch for the draft experience" do
      stub_config_by_experience(experiences: [draft_experience])
      ctx = build_context

      ctx.set_preview(experience_id: "900001", variation_id: "900101")

      expect(a_request(:get, %r{config/sdk-key-1})).to have_been_made.times(1)
    end
  end

  describe "forced-decision precedence over a stored decision (AC5)" do
    it "still forces the preview variation for a visitor already bucketed into a DIFFERENT variation" do
      visitor_id = "visitor-preview-precedence"
      data_store_manager.merge_visitor_data(account_id, project_id, visitor_id) do |_current|
        { "bucketing" => { exp_id => other_variation_id } }
      end
      ctx = build_context(visitor_id: visitor_id, attributes: matching_attrs)

      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      result = ctx.run_experience(exp_key)

      expect(result.id).to eq(forced_variation_id)
      expect(result.id).not_to eq(other_variation_id)
    end

    it "leaves the visitor's stored decision for the experience untouched (never re-persists the forced pick)" do
      visitor_id = "visitor-preview-store-untouched"
      store_key = data_store_manager.visitor_key(account_id, project_id, visitor_id)
      data_store_manager.merge_visitor_data(account_id, project_id, visitor_id) do |_current|
        { "bucketing" => { exp_id => other_variation_id } }
      end
      ctx = build_context(visitor_id: visitor_id, attributes: matching_attrs)

      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      ctx.run_experience(exp_key)

      expect(store.get(store_key)["bucketing"][exp_id]).to eq(other_variation_id)
    end
  end

  describe "inert on bad input (AC7)" do
    CONTEXT_PREVIEW_INERT_INPUT_TABLE.each do |row|
      it "stays unset for #{row[:label]} (warns, never raises, normal decisioning on this context is unaffected)" do
        stub_config_by_experience(experiences: row[:fetch_experiences]) if row[:stub_fetch]
        ctx = build_context(attributes: matching_attrs)

        expect { ctx.set_preview(experience_id: row[:experience_id], variation_id: row[:variation_id]) }
          .not_to raise_error

        # Preview stayed unset: a normal decision on this SAME context, for
        # the SAME experience, proceeds exactly as if set_preview were never
        # called (real bucketing, not a forced pick).
        result = ctx.run_experience(exp_key)
        expect(result).to be_a(ConvertSdk::BucketedVariation)
        expect(variation_ids).to include(result.id)
        expect(warn_messages).to include("Context#set_preview")
      end
    end
  end

  describe "isolation across contexts from the same client (AC7)" do
    it "does not leak preview state into a second context for the same experience" do
      preview_ctx = build_context(visitor_id: "preview-owner", attributes: matching_attrs)
      other_ctx = build_context(visitor_id: "other-visitor", attributes: non_matching_attrs)

      preview_ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      preview_ctx.run_experience(exp_key)

      # other_ctx never had preview set AND its attrs fail the real audience
      # gate — if preview state had leaked, this would be forced into
      # forced_variation_id instead of gating normally (NO_DATA_FOUND).
      expect(other_ctx.run_experience(exp_key)).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end

    it "never mutates the shared installed-config experience entity (guard against the JS SDK-7 leak)" do
      before_entity = data_manager.experience_by_key(exp_key)
      before_snapshot = stringify(before_entity)

      ctx = build_context(attributes: matching_attrs)
      ctx.set_preview(experience_id: exp_id, variation_id: forced_variation_id)
      ctx.run_experience(exp_key)

      after_entity = data_manager.experience_by_key(exp_key)
      expect(after_entity).to equal(before_entity) # same frozen object, never swapped/rebuilt
      expect(stringify(after_entity)).to eq(before_snapshot) # and its VALUE is byte-identical
    end
  end
end
