# frozen_string_literal: true

require "spec_helper"

# CAP-1 — the per-call experience_keys control on Context#run_feature /
# #run_features: which experiences a feature read decides, and which sticky
# assignments it therefore commits. SD-2's non-array rule is pinned by a Hash
# as well as a String — a rescue-shaped guard passes the String and fails it.

module ExpKeysVector
  ACCOUNT_ID = "10022898"
  PROJECT_ID = "10025986"
  A_KEY = "exp-a"
  B_KEY = "exp-b"
  A_ID = "300001"
  B_ID = "300002"
  A_VARIATION = "400001"
  B_VARIATION = "400002"
  A_PREVIEW_VARIATION = "400009"
  FEATURE_A = "feature-a"
  FEATURE_B = "feature-b"
  FEATURE_C = "feature-c"
  RESERVED = "experience_keys"
  VISITOR = "visitor-1"

  # Sentinel for "no per-call hash at all", distinct from an explicit nil value.
  ABSENT = :__no_per_call_hash__

  # Every declared feature, and the experience that carries each carried one.
  DECLARED = [FEATURE_A, FEATURE_B, FEATURE_C].freeze
  CARRIERS = {
    A_KEY => { feature: FEATURE_A, experience_id: A_ID },
    B_KEY => { feature: FEATURE_B, experience_id: B_ID }
  }.freeze
end

# Each row is one experience_keys input and the experiences it must decide.
# +warned+ is the SD-2 guard's observable half; the decided set is the other.
EXPERIENCE_KEYS_EDGE_TABLE = [
  { label: "no per-call hash at all", filter: ExpKeysVector::ABSENT,
    decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: false },
  { label: "an explicit nil value", filter: nil,
    decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: false },
  { label: "an empty array (D-6 — empty means no filter, never match-nothing)", filter: [],
    decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: false },
  { label: "one unknown key among known ones", filter: [ExpKeysVector::A_KEY, "nope"],
    decides: [ExpKeysVector::A_KEY], warned: false },
  { label: "every key unknown", filter: %w[nope nope2], decides: [], warned: false },
  { label: "a symbol element", filter: [ExpKeysVector::A_KEY.to_sym],
    decides: [ExpKeysVector::A_KEY], warned: false },
  { label: "a String (SD-2 — raises today at the engine)", filter: ExpKeysVector::A_KEY,
    decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: true },
  { label: "a Hash (SD-2 — never raises; disables everything without an Array test)",
    filter: { "a" => 1 }, decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: true },
  { label: "an Integer (SD-2)", filter: 5,
    decides: [ExpKeysVector::A_KEY, ExpKeysVector::B_KEY], warned: true }
].freeze

# The same control on the singular entry point, which resolves feature-b.
EXPERIENCE_KEYS_SINGLE_TABLE = [
  { label: "its carrying experience is included", filter: [ExpKeysVector::B_KEY],
    status: ConvertSdk::FeatureStatus::ENABLED, warned: false },
  { label: "its carrying experience is excluded", filter: [ExpKeysVector::A_KEY],
    status: ConvertSdk::FeatureStatus::DISABLED, warned: false },
  { label: "every key unknown", filter: %w[nope],
    status: ConvertSdk::FeatureStatus::DISABLED, warned: false },
  { label: "a Hash degrades to every experience (SD-2)", filter: { "a" => 1 },
    status: ConvertSdk::FeatureStatus::ENABLED, warned: true }
].freeze

# CAP-1 accepts the reserved key in both public forms (SDK-1's source rule for
# a Context-local destination: raw per-call hash, symbol then string).
EXPERIENCE_KEYS_FORMS = [ExpKeysVector::RESERVED.to_sym, ExpKeysVector::RESERVED].freeze

RSpec.describe "Per-call experience_keys on the feature entry points (CAP-1)" do
  ExpKeysVector.constants.each do |const|
    define_method(const.to_s.downcase) { ExpKeysVector.const_get(const) }
  end

  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }
  let(:feature_manager) { ConvertSdk::FeatureManager.new(data_manager: data_manager, log_manager: log_manager) }
  let(:experience_manager) { ConvertSdk::ExperienceManager.new(data_manager: data_manager, log_manager: log_manager) }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # A running 100%-traffic variation carrying exactly one fullStackFeature change.
  def build_variation(variation_id, feature_id, traffic)
    { "id" => variation_id, "name" => "variation-#{variation_id}", "status" => "running",
      "is_baseline" => traffic.positive?, "key" => "#{variation_id}-key",
      "traffic_allocation" => traffic,
      "changes" => [{ "id" => "5#{variation_id}", "type" => "fullStackFeature",
                      "data" => { "feature_id" => feature_id,
                                  "variables_data" => { "headline" => "headline-#{variation_id}" } } }] }
  end

  # Empty audiences + a single 100%-traffic running variation make the bucket
  # deterministic; the optional 0%-traffic arm exists only to be forced.
  def build_experience(experience_id, key, feature_id, variation_id, preview_variation: nil)
    variations = [build_variation(variation_id, feature_id, 100.0)]
    variations << build_variation(preview_variation, feature_id, 0.0) if preview_variation
    { "id" => experience_id, "name" => key, "key" => key, "type" => "a/b_fullstack", "status" => "active",
      "environments" => ["live"], "audiences" => [], "variations" => variations }
  end

  def build_feature(feature_id, key)
    { "id" => feature_id, "name" => key, "key" => key,
      "variables" => [{ "key" => "headline", "type" => "string" }] }
  end

  # Two experiences carrying a DISTINCT feature each, plus a declared-but-uncarried third.
  let(:envelope) do
    { "account_id" => account_id, "project" => { "id" => project_id },
      "audiences" => [], "segments" => [], "goals" => [],
      "features" => [build_feature("20001", feature_a), build_feature("20002", feature_b),
                     build_feature("20003", feature_c)],
      "experiences" => [build_experience(a_id, a_key, "20001", a_variation,
                                         preview_variation: a_preview_variation),
                        build_experience(b_id, b_key, "20002", b_variation)] }
  end

  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { account_id }, project_resolver: -> { project_id }
    )
    dm.install_config(stringify(envelope))
    dm
  end

  def build_context(visitor_id = visitor)
    ConvertSdk::Context.new(
      visitor_id: visitor_id, attributes: { "environment" => "live" },
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: experience_manager, feature_manager: feature_manager
    )
  end

  # The per-call hash carrying +filter+, or nil when the row supplies none.
  def per_call(filter, form: reserved.to_sym)
    filter.equal?(absent) ? nil : { form => filter }
  end

  # run_feature returns a BucketedFeature or an Array of them; Kernel#Array on a
  # Struct would splat its members, so the single case is unwrapped by hand.
  def statuses_of(result)
    result.is_a?(Array) ? result.map(&:status) : [result.status]
  end

  def enabled_keys(features)
    features.select { |f| f.status == ConvertSdk::FeatureStatus::ENABLED }.map(&:key).sort
  end

  # The experience ids this visitor's persisted StoreData carries a sticky
  # variation assignment for — the CAP-1 side effect, read after the fact.
  def sticky_experience_ids(visitor_id = visitor)
    stored = store.get(data_store_manager.visitor_key(account_id, project_id, visitor_id))
    bucketing = stored.is_a?(Hash) ? stored["bucketing"] : nil
    bucketing.is_a?(Hash) ? bucketing.keys.sort : []
  end

  def warned_about_reserved?
    sink.entries.any? { |level, message| level == :warn && message.include?(reserved) }
  end

  def expected_features(row)
    row[:decides].map { |key| carriers.fetch(key)[:feature] }.sort
  end

  def expected_sticky(row)
    row[:decides].map { |key| carriers.fetch(key)[:experience_id] }.sort
  end

  describe "CAP-1 success criterion" do
    it "reports every carried feature enabled when the caller narrows nothing" do
      results = build_context.run_features

      expect(enabled_keys(results)).to eq([feature_a, feature_b])
      expect(results.map(&:key).sort).to eq(declared.sort)
    end

    it "enables only the named experience's feature and reports the other DISABLED, not omitted" do
      results = build_context.run_features({ experience_keys: [a_key] })

      expect(enabled_keys(results)).to eq([feature_a])
      expect(results.map(&:key).sort).to eq(declared.sort)
      excluded = results.find { |f| f.key == feature_b }
      expect(excluded.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
    end

    it "returns a DISABLED BucketedFeature carrying id/name/key when the feature's experience is excluded" do
      result = build_context.run_feature(feature_b, { experience_keys: [a_key] })

      expect(result).to be_a(ConvertSdk::BucketedFeature)
      expect(result.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
      expect(result.id).to eq("20002")
      expect(result.name).to eq(feature_b)
      expect(result.key).to eq(feature_b)
      expect(result.error?).to be(false)
      expect(result).to be_frozen
    end
  end

  describe "#run_features — every experience_keys input" do
    EXPERIENCE_KEYS_EDGE_TABLE.each do |row|
      it "decides #{row[:decides].inspect} given #{row[:label]}" do
        results = build_context.run_features(per_call(row[:filter]))

        expect(enabled_keys(results)).to eq(expected_features(row))
        expect(results.map(&:key).sort).to eq(declared.sort)
        expect(sticky_experience_ids).to eq(expected_sticky(row))
        expect(warned_about_reserved?).to be(row[:warned])
      end
    end
  end

  describe "#run_feature — the same control on the singular entry point" do
    EXPERIENCE_KEYS_SINGLE_TABLE.each do |row|
      it "resolves feature-b as #{row[:status]} when #{row[:label]}" do
        result = build_context.run_feature(feature_b, per_call(row[:filter]))

        expect(statuses_of(result)).to eq([row[:status]])
        expect(warned_about_reserved?).to be(row[:warned])
      end
    end
  end

  describe "the reserved key in both public forms" do
    EXPERIENCE_KEYS_FORMS.each do |form|
      it "narrows identically given the #{form.class} form" do
        results = build_context.run_features(per_call([a_key], form: form))

        expect(enabled_keys(results)).to eq([feature_a])
        expect(sticky_experience_ids).to eq([a_id])
      end
    end
  end

  describe "sticky-write scoping — the side effect CAP-1 exists for" do
    it "commits a sticky assignment for EVERY configured experience on an unfiltered single-feature read" do
      build_context.run_feature(feature_b)

      expect(sticky_experience_ids).to eq([a_id, b_id].sort)
    end

    it "commits only the named experience's assignment once the read is narrowed" do
      build_context.run_feature(feature_b, { experience_keys: [b_key] })

      expect(sticky_experience_ids).to eq([b_id])
    end

    it "commits nothing when no named key matches a configured experience" do
      build_context.run_features({ experience_keys: %w[nope] })

      expect(sticky_experience_ids).to eq([])
    end
  end

  describe "preview interaction — suppress-only, never a force" do
    def preview_context
      ctx = build_context
      ctx.set_preview(experience_id: a_id, variation_id: a_preview_variation)
      ctx
    end

    it "excludes a previewed experience like any other when it is filtered out" do
      ctx = preview_context

      results = ctx.run_features({ experience_keys: [b_key] })

      expect(enabled_keys(results)).to eq([feature_b])
      expect(results.find { |f| f.key == feature_a }.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
    end

    it "leaves the preview active — the previewed experience is still forced afterwards" do
      ctx = preview_context

      ctx.run_features({ experience_keys: [b_key] })

      expect(ctx.run_experience(a_key).id).to eq(a_preview_variation)
    end

    it "keeps the whole call zero-trace — a filtered feature read still persists nothing" do
      ctx = preview_context

      ctx.run_features({ experience_keys: [a_key] })

      expect(sticky_experience_ids).to eq([])
    end
  end

  describe "non-goal — the feature-key filter stays unreachable from Context" do
    it "treats a per-call features key as an ordinary visitor property, keeping the DISABLED padding" do
      results = build_context.run_features({ features: [feature_a] })

      expect(results.map(&:key).sort).to eq(declared.sort)
      expect(enabled_keys(results)).to eq([feature_a, feature_b])
    end

    it "enumerates no features row among the reserved per-call keys" do
      enumeration = ConvertSdk::Context::RESERVED_KEYS
      rows = enumeration.is_a?(Hash) ? enumeration.keys : enumeration.to_a
      names = rows.map { |row| row.is_a?(Hash) ? (row[:key] || row["key"]) : row }.map(&:to_s)

      expect(names).not_to include("features")
    end
  end
end
