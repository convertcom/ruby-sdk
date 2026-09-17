# frozen_string_literal: true

require "spec_helper"

# CAP-2 — the per-call type_casting control on Context#run_feature /
# #run_features: cast to the declared type by default, as stored in config under
# an explicit boolean false alone (D-8, where Ruby diverges from the reference
# SDK's presence test). The casting-ON column is measured, not SPEC.md's (SD-3).

module TypeCastVector
  ACCOUNT_ID = "10022898"
  PROJECT_ID = "10025986"
  EXP_KEY = "exp-cast"
  EXP_ID = "300011"
  VARIATION_ID = "400011"
  FEATURE_KEY = "feature-cast"
  FEATURE_ID = "20011"
  OTHER_FEATURE = "feature-uncarried"
  OTHER_FEATURE_ID = "20012"
  RESERVED = "type_casting"
  VISITOR = "visitor-1"
  MIS_INT = "mis_int"
  MIS_FLOAT = "mis_float"
  UNDECLARED = "loose"

  # Sentinel for "no per-call hash at all", distinct from an explicit nil value.
  ABSENT = :__no_per_call_hash__
end

# One row per declared variable: what config stores, and what casting makes of
# it. The 0 / 0.0 rows are the mis-declared pair; SPEC.md claims a raw string
# there and is wrong (SD-3) — cast_integer/cast_float return the defaults.
TYPE_CASTING_VARIABLES = [
  { name: "count", type: "integer", stored: "40", cast: 40 },
  { name: "payload", type: "json", stored: '{"k":1}', cast: { "k" => 1 } },
  { name: TypeCastVector::MIS_INT, type: "integer", stored: "abc", cast: 0 },
  { name: TypeCastVector::MIS_FLOAT, type: "float", stored: "abc", cast: 0.0 },
  { name: "broken_json", type: "json", stored: "{not json", cast: "{not json" },
  { name: TypeCastVector::UNDECLARED, type: nil, stored: "as-is", cast: "as-is" }
].freeze

TYPE_CASTING_STORED = TYPE_CASTING_VARIABLES.to_h { |row| [row[:name], row[:stored]] }.freeze
TYPE_CASTING_CAST = TYPE_CASTING_VARIABLES.to_h { |row| [row[:name], row[:cast]] }.freeze

# Every per-call type_casting value, and whether casting survives it (D-8).
TYPE_CASTING_VALUES = [
  { label: "no per-call hash at all", value: TypeCastVector::ABSENT, casts: true },
  { label: "an explicit nil — the reference SDK disables here, Ruby must not (D-8)",
    value: nil, casts: true },
  { label: "the boolean false", value: false, casts: false },
  { label: "the string \"false\"", value: "false", casts: true },
  { label: "the integer 0", value: 0, casts: true },
  { label: "the boolean true", value: true, casts: true }
].freeze

# The two values every unchanged-behaviour block is driven over.
TYPE_CASTING_BOTH_VALUES = [
  { label: "no per-call hash", value: TypeCastVector::ABSENT },
  { label: "an explicit false", value: false }
].freeze

TYPE_CASTING_ENTRY_POINTS = %i[run_feature run_features].freeze
TYPE_CASTING_FORMS = [TypeCastVector::RESERVED.to_sym, TypeCastVector::RESERVED].freeze

TypeCastStack = Struct.new(:context, :store, :data_store_manager)

RSpec.describe "Per-call type_casting on the feature entry points (CAP-2)" do
  TypeCastVector.constants.each do |const|
    define_method(const.to_s.downcase) { TypeCastVector.const_get(const) }
  end

  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }
  let(:stack) { build_stack }

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # A running 100%-traffic variation carrying the whole stored variable map.
  def build_variation
    { "id" => variation_id, "name" => "variation-#{variation_id}", "status" => "running",
      "is_baseline" => true, "key" => "#{variation_id}-key", "traffic_allocation" => 100.0,
      "changes" => [{ "id" => "5#{variation_id}", "type" => "fullStackFeature",
                      "data" => { "feature_id" => feature_id,
                                  "variables_data" => TYPE_CASTING_STORED } }] }
  end

  # The UNDECLARED row is deliberately absent here: no declaration is what makes
  # FeatureManager warn and pass the value through uncast.
  def declared_variables
    TYPE_CASTING_VARIABLES.reject { |row| row[:type].nil? }
                          .map { |row| { "key" => row[:name], "type" => row[:type] } }
  end

  def declared_features
    [{ "id" => feature_id, "name" => feature_key, "key" => feature_key,
       "variables" => declared_variables },
     { "id" => other_feature_id, "name" => other_feature, "key" => other_feature, "variables" => [] }]
  end

  # Empty audiences + a single 100%-traffic running variation make the bucket
  # deterministic; the second feature is declared but carried by nothing.
  def envelope
    { "account_id" => account_id, "project" => { "id" => project_id },
      "audiences" => [], "segments" => [], "goals" => [], "features" => declared_features,
      "experiences" => [{ "id" => exp_id, "name" => exp_key, "key" => exp_key,
                          "type" => "a/b_fullstack", "status" => "active",
                          "environments" => ["live"], "audiences" => [],
                          "variations" => [build_variation] }] }
  end

  def build_data_manager(data_store_manager)
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { account_id }, project_resolver: -> { project_id }
    )
    dm.install_config(stringify(envelope))
    dm
  end

  def build_context(data_manager, data_store_manager)
    ConvertSdk::Context.new(
      visitor_id: visitor, attributes: { "environment" => "live" },
      data_manager: data_manager, data_store_manager: data_store_manager,
      event_manager: event_manager, log_manager: log_manager, config: config,
      experience_manager: ConvertSdk::ExperienceManager.new(data_manager: data_manager,
                                                            log_manager: log_manager),
      feature_manager: ConvertSdk::FeatureManager.new(data_manager: data_manager,
                                                      log_manager: log_manager)
    )
  end

  # A Context over its OWN store, so two stacks decide independently.
  def build_stack
    store = ConvertSdk::Stores::MemoryStore.new
    data_store_manager = ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store)
    data_manager = build_data_manager(data_store_manager)
    TypeCastStack.new(build_context(data_manager, data_store_manager), store, data_store_manager)
  end

  # The per-call hash carrying +value+, or nil when the row supplies none.
  def per_call(value, form: reserved.to_sym)
    value.equal?(absent) ? nil : { form => value }
  end

  def invoke(entry, per_call_hash, ctx: stack.context)
    entry == :run_feature ? ctx.run_feature(feature_key, per_call_hash) : ctx.run_features(per_call_hash)
  end

  # run_feature returns a BucketedFeature or an Array of them; Kernel#Array on a
  # Struct would splat its members, so the single case is unwrapped by hand.
  def features_from(result)
    result.is_a?(Array) ? result : [result]
  end

  # The carried feature's variable map as +entry+ reports it.
  def variables_via(entry, per_call_hash = nil, ctx: stack.context)
    features_from(invoke(entry, per_call_hash, ctx: ctx)).find { |f| f.key == feature_key }&.variables
  end

  def enabled_keys(features)
    features.select { |f| f.status == ConvertSdk::FeatureStatus::ENABLED }.map(&:key).sort
  end

  def warned_about_undeclared_type?
    sink.entries.any? do |level, message|
      level == :warn && message.include?("variable type not found name=#{undeclared}")
    end
  end

  # The enabled feature's experience provenance — everything the decision fixed,
  # with the variables (the only thing the flag may touch) left out.
  def provenance_of(target, per_call_hash)
    resolved = features_from(invoke(:run_features, per_call_hash, ctx: target.context))
    resolved.find { |f| f.key == feature_key }.to_h.except(:variables)
  end

  # The visitor's persisted sticky assignments — experience id => variation.
  def sticky_bucketing(target)
    stored = target.store.get(target.data_store_manager.visitor_key(account_id, project_id, visitor))
    stored.is_a?(Hash) ? stored["bucketing"] : nil
  end

  describe "CAP-2 success criterion — cast by default, as stored under an explicit false" do
    TYPE_CASTING_ENTRY_POINTS.each do |entry|
      TYPE_CASTING_VARIABLES.each do |row|
        declared = row[:type] || "nothing"
        it "#{entry}: #{row[:name]} declared #{declared} is #{row[:cast].inspect} cast, " \
           "#{row[:stored].inspect} stored" do
          expect(variables_via(entry)[row[:name]]).to eql(row[:cast])
          expect(variables_via(entry, per_call(false))[row[:name]]).to eql(row[:stored])
        end
      end
    end

    # json is stored as a String, so switching casting off is genuinely lossy
    # for it — that is what "as stored" means, and it is intended.
    it "hands back the json variable's stored String, not the parsed Hash" do
      expect(variables_via(:run_features)["payload"]).to eq({ "k" => 1 })
      expect(variables_via(:run_features, per_call(false))["payload"]).to eq('{"k":1}')
    end
  end

  describe "the mis-declared variable — the reason a caller wants the flag off (SD-3)" do
    it "degrades a non-numeric string to 0 and 0.0, indistinguishable from a legitimate zero" do
      variables = variables_via(:run_features)

      expect(variables[mis_int]).to eql(0)
      expect(variables[mis_float]).to eql(0.0)
    end

    it "hands back the stored \"abc\" under an explicit false, under both declarations" do
      variables = variables_via(:run_features, per_call(false))

      expect(variables.values_at(mis_int, mis_float)).to eq(%w[abc abc])
    end
  end

  describe "only the boolean false turns casting off (D-8)" do
    TYPE_CASTING_VALUES.each do |row|
      it "leaves the variables #{row[:casts] ? "cast" : "as stored"} given #{row[:label]}" do
        expected = row[:casts] ? TYPE_CASTING_CAST : TYPE_CASTING_STORED

        expect(variables_via(:run_features, per_call(row[:value]))).to eq(expected)
      end
    end
  end

  describe "the reserved key in both public forms, on both entry points" do
    TYPE_CASTING_ENTRY_POINTS.each do |entry|
      TYPE_CASTING_FORMS.each do |form|
        it "#{entry}: a #{form.class} key disables casting identically" do
          expect(variables_via(entry, per_call(false, form: form))).to eq(TYPE_CASTING_STORED)
        end
      end
    end
  end

  describe "no effect on the decision — the flag acts after it" do
    let(:casting_on) { build_stack }
    let(:casting_off) { build_stack }

    it "reports the same roster and the same enabled feature keys under both values" do
      on_results = casting_on.context.run_features
      off_results = casting_off.context.run_features(per_call(false))

      expect(enabled_keys(off_results)).to eq(enabled_keys(on_results))
      expect(off_results.map(&:key).sort).to eq(on_results.map(&:key).sort)
      expect(enabled_keys(on_results)).to eq([feature_key])
    end

    it "resolves the same variation and commits the same sticky assignment" do
      casting_on.context.run_features
      casting_off.context.run_features(per_call(false))

      expect(sticky_bucketing(casting_off)).to eq(sticky_bucketing(casting_on))
      expect(sticky_bucketing(casting_on)).not_to be_empty
    end

    it "carries the same experience provenance on the enabled feature" do
      on_feature = provenance_of(casting_on, nil)
      off_feature = provenance_of(casting_off, per_call(false))

      expect(off_feature).to eq(on_feature)
      expect(on_feature.compact).not_to be_empty
    end
  end

  describe "the DISABLED padding entries are unaffected under either value" do
    TYPE_CASTING_BOTH_VALUES.each do |row|
      it "carries no variables given #{row[:label]}" do
        padded = features_from(invoke(:run_features, per_call(row[:value])))
                 .find { |f| f.key == other_feature }

        expect(padded.status).to eq(ConvertSdk::FeatureStatus::DISABLED)
        expect(padded.variables).to be_nil
      end
    end
  end

  describe "the undeclared-type warn still fires under both values (D-8)" do
    TYPE_CASTING_BOTH_VALUES.each do |row|
      it "warns for the variable with no declared type given #{row[:label]}" do
        invoke(:run_features, per_call(row[:value]))

        expect(warned_about_undeclared_type?).to be(true)
      end
    end
  end

  describe "n/a on the experience pair by design, not missing from it" do
    it "returns a BucketedVariation with no variable map to act on, only raw changes" do
      variation = stack.context.run_experience(exp_key, per_call(false))

      expect(variation).to be_a(ConvertSdk::BucketedVariation)
      expect(variation).not_to respond_to(:variables)
      expect(variation.changes.first["data"]["variables_data"]).to eq(TYPE_CASTING_STORED)
    end
  end
end
