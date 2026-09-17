# frozen_string_literal: true

require "spec_helper"

# CAP-3 — the reserved per-call keys Context#decision_attributes accepts, where
# each one lands, and the two engine-readable keys it never lifts (SD-4, D-5).

module ReservedKeyVector
  VISITOR_ID = "visitor-1"
  EXP_KEY = "test-experience-ab-fullstack-2"
  FEATURE_KEY = "feature-1"
  SEGMENT_KEY = "test-segments-1"
  SDK_KEY = "sdk-key-1"
  PREVIEW_EXP_ID = "100218245"
  PREVIEW_VARIATION_ID = "100299456"
  MATCHING = { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" }.freeze
end

RESERVED_DECISION_SEAMS = {
  run_experience: %i[experience_manager select_variation],
  run_experiences: %i[experience_manager select_variations],
  run_feature: %i[feature_manager run_feature],
  run_features: %i[feature_manager run_features]
}.freeze

RESERVED_COLLABORATOR_CLASSES = {
  experience_manager: ConvertSdk::ExperienceManager,
  feature_manager: ConvertSdk::FeatureManager
}.freeze

# Stand-in returns so each entry point completes without deciding anything.
RESERVED_SEAM_RESULTS = {
  select_variation: ConvertSdk::RuleError::NO_DATA_FOUND,
  select_variations: [],
  run_feature: ConvertSdk::BucketedFeature.new(key: ReservedKeyVector::FEATURE_KEY,
                                               status: ConvertSdk::FeatureStatus::DISABLED),
  run_features: []
}.freeze

# The engine envelope among a seam's arguments, identified by SHAPE: seam arities
# differ and the feature seams trail a keyword hash, which never carries this key.
RESERVED_ENGINE_ENVELOPE = ->(arg) { arg.is_a?(Hash) && arg.key?(:visitor_properties) }

RESERVED_ENVELOPE_DESTINATIONS = [
  { key: "location_properties", destination: :location_properties,
    value: { "url" => "https://example.test/cart" } },
  { key: "environment", destination: :environment, value: "staging" }
].freeze

RESERVED_CONTEXT_LOCAL_KEYS = [
  { key: "enable_tracking", value: false },
  { key: "ruleData", value: { "enabled" => true } }
].freeze

# CAP-3's negative list, probed as the future edit it exists to survive: each row
# is ADDED to RESERVED_KEYS as a lifted row, and +envelope+ is what the engine
# envelope must still show for that key while the caller pushes +value+.
RESERVED_NOT_LIFTED_PROBES = [
  { key: "enable_storage", value: false, envelope: true },
  { key: "update_visitor_properties", value: "caller-value", envelope: nil }
].freeze

RSpec.describe "Reserved per-call key enumeration (CAP-3)" do
  ReservedKeyVector.constants.each do |const|
    define_method(const.to_s.downcase) { ReservedKeyVector.const_get(const) }
  end

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

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  def build_context(attributes: nil, **overrides)
    ConvertSdk::Context.new(
      visitor_id: visitor_id, attributes: attributes,
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: experience_manager, feature_manager: feature_manager,
      segments_manager: segments_manager, **overrides
    )
  end

  def invoke(ctx, entry, per_call)
    case entry
    when :run_experience then ctx.run_experience(exp_key, per_call)
    when :run_experiences then ctx.run_experiences(per_call)
    when :run_feature then ctx.run_feature(feature_key, per_call)
    else ctx.run_features(per_call)
    end
  end

  # Drives +entry+ through the PUBLIC Context API with a recording collaborator,
  # and returns the engine envelope Context built for it.
  def envelope_for(entry, attributes: nil, per_call: nil, preview: false)
    collaborator, seam = RESERVED_DECISION_SEAMS.fetch(entry)
    recorder = instance_double(RESERVED_COLLABORATOR_CLASSES.fetch(collaborator))
    captured = nil
    allow(recorder).to receive(seam) do |*args|
      captured = args.find(&RESERVED_ENGINE_ENVELOPE)
      RESERVED_SEAM_RESULTS.fetch(seam)
    end
    ctx = build_context(attributes: attributes, **{ collaborator => recorder })
    ctx.set_preview(experience_id: preview_exp_id, variation_id: preview_variation_id) if preview
    invoke(ctx, entry, per_call)
    captured
  end

  describe "the enumeration itself (set equality, both directions)" do
    # The implementation owns the literal shape; only the key set is pinned.
    def key_names(enumeration)
      rows = enumeration.is_a?(Hash) ? enumeration.keys : enumeration.to_a
      rows.map { |row| row.is_a?(Hash) ? (row[:key] || row["key"]) : row }.map(&:to_s).sort
    end

    it "enumerates exactly the six reserved per-call keys (SD-4 includes ruleData)" do
      expect(key_names(ConvertSdk::Context::RESERVED_KEYS))
        .to eq(%w[enable_tracking environment experience_keys location_properties ruleData type_casting])
    end

    it "lists exactly the two engine-readable keys the seam never lifts (D-5)" do
      expect(key_names(ConvertSdk::Context::NOT_LIFTED))
        .to eq(%w[enable_storage update_visitor_properties])
    end
  end

  describe "positive direction — an envelope-destination key reaches its destination" do
    RESERVED_DECISION_SEAMS.each_key do |entry|
      RESERVED_ENVELOPE_DESTINATIONS.each do |row|
        it "#{entry}: a per-call #{row[:key]} lands at envelope[#{row[:destination].inspect}]" do
          envelope = envelope_for(entry, attributes: ReservedKeyVector::MATCHING,
                                         per_call: { row[:key] => row[:value] })
          expect(envelope[row[:destination]]).to eq(row[:value])
        end

        it "#{entry}: a per-call #{row[:key]} wins over the context-level value" do
          envelope = envelope_for(entry,
                                  attributes: ReservedKeyVector::MATCHING.merge(row[:key] => "context-level"),
                                  per_call: { row[:key] => row[:value] })
          expect(envelope[row[:destination]]).to eq(row[:value])
        end

        it "#{entry}: accepts the symbol form of #{row[:key]} identically" do
          envelope = envelope_for(entry, attributes: ReservedKeyVector::MATCHING,
                                         per_call: { row[:key].to_sym => row[:value] })
          expect(envelope[row[:destination]]).to eq(row[:value])
        end
      end
    end
  end

  describe "negative direction — a NOT_LIFTED key never reaches the envelope from a caller" do
    it "enable_storage: a caller passing false does NOT disable persistence" do
      envelope = envelope_for(:run_experience, attributes: ReservedKeyVector::MATCHING,
                                               per_call: { enable_storage: false })
      expect(envelope[:enable_storage]).to be(true)
    end

    it "update_visitor_properties: the seam never supplies it (D-5)" do
      envelope = envelope_for(:run_feature, attributes: ReservedKeyVector::MATCHING,
                                            per_call: { update_visitor_properties: true })
      expect(envelope).not_to have_key(:update_visitor_properties)
    end

    # The list filters the ENVELOPE; it must not strip the merged map, which is
    # what the AUDIENCE step matches against.
    it "both still ride inside visitor_properties, where they match no control" do
      envelope = envelope_for(:run_experience, attributes: ReservedKeyVector::MATCHING,
                                               per_call: { enable_storage: false,
                                                           update_visitor_properties: true })
      expect(envelope[:visitor_properties])
        .to include("enable_storage" => false, "update_visitor_properties" => true)
    end
  end

  describe "enable_storage stays owned by preview alone" do
    it "is false on a preview-active context even when the caller passes true" do
      envelope = envelope_for(:run_feature, attributes: ReservedKeyVector::MATCHING,
                                            per_call: { enable_storage: true }, preview: true)
      expect(envelope[:enable_storage]).to be(false)
    end
  end

  describe "source convention — envelope keys read the MERGED map" do
    RESERVED_ENVELOPE_DESTINATIONS.each do |row|
      it "#{row[:key]}: a context-level value reaches the envelope with no per-call hash at all" do
        envelope = envelope_for(:run_experience, attributes: { row[:key] => row[:value] }, per_call: nil)
        expect(envelope[row[:destination]]).to eq(row[:value])
      end
    end
  end

  describe "source convention — Context-local keys are not envelope keys" do
    RESERVED_DECISION_SEAMS.each_key do |entry|
      RESERVED_CONTEXT_LOCAL_KEYS.each do |row|
        it "#{entry}: a per-call #{row[:key]} never becomes a top-level envelope key" do
          envelope = envelope_for(entry, attributes: ReservedKeyVector::MATCHING,
                                         per_call: { row[:key] => row[:value] })
          expect(envelope).not_to have_key(row[:key].to_sym)
        end
      end
    end
  end

  describe "source convention — enable_tracking reads the RAW per-call hash only" do
    let(:tracking_config) do
      ConvertSdk::Config.new(
        log_manager: log_manager, data: ConfigFixture.config, sdk_key: sdk_key,
        track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
        flush_interval: nil, tracking: true
      )
    end

    let(:api_manager) do
      ConvertSdk::ApiManager.new(
        config: tracking_config, data_manager: data_manager,
        http_client: ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1),
        event_manager: event_manager, log_manager: log_manager
      )
    end

    def tracked_context(attributes)
      build_context(attributes: attributes, config: tracking_config, api_manager: api_manager)
    end

    it "a CONTEXT-level enable_tracking:false is INERT — tracking stays on" do
      tracked_context(ReservedKeyVector::MATCHING.merge("enable_tracking" => false)).run_experience(exp_key)
      expect(api_manager.queue.size).to be > 0
    end

    [:enable_tracking, "enable_tracking"].each do |form|
      it "the same flag passed PER-CALL suppresses the enqueue (#{form.class} key)" do
        tracked_context(ReservedKeyVector::MATCHING).run_experience(exp_key, form => false)
        expect(api_manager.queue.size).to eq(0)
      end
    end
  end

  describe "ruleData (SD-4) — scoped to run_custom_segments" do
    def captured_segment_rule(per_call)
      recorder = instance_double(ConvertSdk::SegmentsManager)
      captured = nil
      allow(recorder).to receive(:select_custom_segments) do |*args, **_kwargs|
        captured = args[2]
        nil
      end
      build_context(attributes: ReservedKeyVector::MATCHING, segments_manager: recorder)
        .run_custom_segments([segment_key], per_call)
      captured
    end

    [:ruleData, "ruleData"].each do |form|
      it "reaches SegmentsManager through visitor_properties (#{form.class} key)" do
        expect(captured_segment_rule(form => { "enabled" => true })).to include("enabled" => true)
      end
    end

    it "still merges the context attributes underneath the per-call ruleData" do
      expect(captured_segment_rule(ruleData: { "enabled" => true })).to include("varName1" => "value1")
    end
  end

  # CAP-3 linkage: each stub below is DERIVED from the real constant, so it holds
  # whichever shape (Hash-of-rows or Array-of-rows) the implementation picks.
  describe "linkage — the translation seam is built FROM the enumeration (CAP-3)" do
    let(:probe_key) { "synthetic_probe_key" }
    let(:plain_attributes) { { "varName1" => "value1" } }
    let(:api_recorder) { instance_double(ConvertSdk::ApiManager, enqueue: nil) }

    def reserved_keys
      ConvertSdk::Context::RESERVED_KEYS
    end

    def row_name(row)
      row.is_a?(Hash) ? (row[:key] || row["key"]) : row
    end

    def payload_for(enumeration, name)
      return enumeration.find { |k, _| k.to_s == name }&.last if enumeration.is_a?(Hash)

      enumeration.find { |row| row_name(row).to_s == name }
    end

    def without_row(enumeration, name)
      return enumeration.reject { |k, _| k.to_s == name } if enumeration.is_a?(Hash)

      enumeration.reject { |row| row_name(row).to_s == name }
    end

    def recase(key, into)
      key.is_a?(Symbol) ? into.to_sym : into
    end

    def rekey(row, into)
      return recase(row, into) unless row.is_a?(Hash)

      field = row.key?(:key) ? :key : "key"
      row.merge(field => recase(row[field], into))
    end

    # Re-keys the +name+ row, carrying its payload — and so its stated destination — across.
    def renamed(enumeration, name, into)
      rest = without_row(enumeration, name)
      raise "no #{name} row in the enumeration" if rest.size == enumeration.size
      return rest + [rekey(payload_for(enumeration, name), into)] unless enumeration.is_a?(Hash)

      key = enumeration.keys.find { |k| k.to_s == name }
      rest.merge(recase(key, into) => enumeration[key])
    end

    # The envelope slot the enumeration itself states for +name+.
    def destination_for(enumeration, name)
      payload = payload_for(enumeration, name)
      stated = payload.is_a?(Hash) ? (payload[:destination] || payload["destination"]) : payload
      stated = name unless stated.is_a?(Symbol) || stated.is_a?(String)
      stated.to_sym
    end

    it "drops environment from the envelope when its row is dropped from the enumeration" do
      stub_const("ConvertSdk::Context::RESERVED_KEYS", without_row(reserved_keys, "environment"))
      envelope = envelope_for(:run_experience, attributes: plain_attributes,
                                               per_call: { "environment" => "staging" })
      expect(envelope[:environment]).to be_nil
    end

    it "carries a per-call key the enumeration GAINED to that row's stated destination" do
      stubbed = renamed(reserved_keys, "environment", probe_key)
      stub_const("ConvertSdk::Context::RESERVED_KEYS", stubbed)
      envelope = envelope_for(:run_experience, attributes: plain_attributes,
                                               per_call: { probe_key => "probe-value" })
      expect(envelope[destination_for(stubbed, probe_key)]).to eq("probe-value")
    end

    it "makes a per-call enable_tracking inert when its row is dropped from the enumeration" do
      stub_const("ConvertSdk::Context::RESERVED_KEYS", without_row(reserved_keys, "enable_tracking"))
      build_context(attributes: ReservedKeyVector::MATCHING, api_manager: api_recorder)
        .run_experience(exp_key, "enable_tracking" => false)
      expect(api_recorder).to have_received(:enqueue)
    end

    # The destination the gained row states, recased to match +payload+'s own keys.
    def with_destination(payload, into)
      return into unless payload.is_a?(Hash)

      field = payload.key?(:destination) ? :destination : "destination"
      payload.merge(field => recase(payload[field], into))
    end

    # A copy of +enumeration+ that GAINS a +name+ row cloned from +from+'s and routed
    # to +name+ — derived from the real constant, like #without_row / #renamed.
    def gaining_row(enumeration, from, name)
      payload = with_destination(payload_for(enumeration, from), name)
      return enumeration + [rekey(payload, name)] unless enumeration.is_a?(Hash)

      key = enumeration.keys.find { |k| k.to_s == from }
      enumeration.merge(recase(key, name) => payload)
    end

    RESERVED_NOT_LIFTED_PROBES.each do |row|
      it "keeps a caller's #{row[:key]} out of the envelope even if the enumeration GAINS its row (D-4)" do
        stub_const("ConvertSdk::Context::RESERVED_KEYS", gaining_row(reserved_keys, "environment", row[:key]))
        envelope = envelope_for(:run_experience, attributes: plain_attributes,
                                                 per_call: { row[:key] => row[:value] })
        expect(envelope[row[:key].to_sym]).to be(row[:envelope])
      end
    end

    it "still persists sticky bucketing when a GAINED enable_storage row carries the caller's false (D-4)" do
      stub_const("ConvertSdk::Context::RESERVED_KEYS", gaining_row(reserved_keys, "environment", "enable_storage"))
      ctx = build_context(attributes: ReservedKeyVector::MATCHING)
      ctx.run_experience(exp_key, "enable_storage" => false)
      expect(ctx.get_visitor_data["bucketing"]).not_to be_empty
    end
  end
end
