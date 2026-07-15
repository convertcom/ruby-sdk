# frozen_string_literal: true

require "spec_helper"

# qs-04 (RB-2) — DataManager wiring for the +bucketed_into_experience_key+
# mutual-exclusion rule: the REAL resolver (built from
# +DataManager#experience_by_key+ + the visitor's stored bucketing map) is
# threaded from +match_rules_by_field+ (which has +visitor_id+) down through
# +match_audiences+ -> +matched_audiences+ -> +RuleManager#is_rule_matched+.
#
# Spec of record: _bmad-output/planning-artifacts/2026-06-05-convert-ruby-sdk/
#   qs-04-mutual-exclusion-rule.md — AC2 (end-to-end exclusion), AC3 (store
#   persistence, row 8), AC4 (zero new inputs), AC5 (read-only), AC6
#   (ALL/ANY combination), AC8 (unknown-target warning).
#
# RB-1 (merged) proved RuleManager applies the contract exactly GIVEN a
# resolver: it accepts an optional `resolver:` keyword threaded through the
# whole OR/AND/OR_WHEN walk, and a `bucketed_into_experience_key` leaf falls
# closed to `false` (negation UNAPPLIED) when NO resolver is threaded at all
# (spec/unit/rule_manager_mutual_exclusion_spec.rb).
#
# THIS file is RB-2: DataManager builds that resolver
# (`mutual_exclusion_resolver`, lib/convert_sdk/data_manager.rb:551-558) and
# threads it through `match_rules_by_field` -> `match_audiences` ->
# `matched_audiences` -> `RuleManager#is_rule_matched`
# (lib/convert_sdk/data_manager.rb:582-583). Every audience carrying this rule
# type is evaluated against the visitor's actual stored bucketing state via
# the wired resolver.
#
# The examples below lock in the real, resolver-backed exclusion behavior:
#   * A visitor already bucketed into the target experience is excluded from
#     the gated experience (subject to negation).
#   * A visitor who never ran the target experience buckets into the gated
#     experience normally.
#   * An unresolvable/unknown target dissolves the leaf and logs a warning
#     naming the key (AC8), while still applying negation to the dissolved
#     `false`.
#
# AC5's read-only assertions are a SAFETY INVARIANT: the resolver never
# buckets the target experience, never writes to the store, and never fires a
# track/event enqueue while evaluating the exclusion rule.
RSpec.describe "qs-04 mutual exclusion — DataManager wiring (RB-2)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: MutualExclusionFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:dsm) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }

  # Build a fresh DataManager + ExperienceManager pair from a config hash and a
  # (possibly shared, for AC3) DataStoreManager — mirrors
  # spec/unit/decision_flow_spec.rb's `build` helper exactly, so this file's
  # conventions match the repo's established decision-flow-spec pattern.
  def build(config_hash = MutualExclusionFixture.config, data_store_manager: dsm)
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { MutualExclusionFixture::ACCOUNT_ID },
      project_resolver: -> { MutualExclusionFixture::PROJECT_ID }
    )
    dm.install_config(config_hash)
    [dm, ConvertSdk::ExperienceManager.new(data_manager: dm, log_manager: log_manager)]
  end

  # AC4 (zero new inputs) folded in EVERYWHERE below: `visitor_properties` is
  # always `{}` unless an example explicitly needs an attribute (AC6).
  def attrs(visitor_properties: {}, **extra)
    { visitor_properties: visitor_properties }.merge(extra)
  end

  def store_key(visitor_id)
    dsm.visitor_key(MutualExclusionFixture::ACCOUNT_ID, MutualExclusionFixture::PROJECT_ID, visitor_id)
  end

  describe "AC2 — end-to-end exclusion (+ AC4 — empty visitor attributes throughout)" do
    it "a visitor already bucketed into exp-a is excluded from exp-b" do
      _, em = build
      visitor = "visitor-ran-a"

      a_decision = em.select_variation(visitor, MutualExclusionFixture::EXP_A_KEY, attrs)
      expect(a_decision).to be_a(ConvertSdk::BucketedVariation)
      expect(a_decision.id).to eq(MutualExclusionFixture::EXP_A_VARIATION_ID)

      b_decision = em.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end

    it "a visitor who never ran exp-a buckets into exp-b normally" do
      _, em = build
      visitor = "visitor-never-ran-a"

      b_decision = em.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(b_decision).to be_a(ConvertSdk::BucketedVariation)
      expect(b_decision.id).to eq(MutualExclusionFixture::EXP_B_VARIATION_ID)
    end
  end

  describe "AC1 — fixture row 5 fidelity: a stored bucketing entry for a DIFFERENT experience " \
           "(exp-b itself) must not falsely satisfy an exclusion rule targeting exp-a" do
    it "buckets normally into exp-b even once the visitor's stored bucketing map already holds " \
       "an entry for exp-b (not exp-a) — proves the resolver checks exp-a's id specifically, " \
       "not \"map non-empty\" (qs-04 row 5: {\"100222\":\"100902\"}, target exp-a, negated true, " \
       "expected matched TRUE)" do
      _, em = build
      visitor = "visitor-row5-fidelity"

      first = em.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(first).to be_a(ConvertSdk::BucketedVariation)
      expect(first.id).to eq(MutualExclusionFixture::EXP_B_VARIATION_ID)

      stored = dsm.get(store_key(visitor))
      expect(stored["bucketing"]).to eq(
        { MutualExclusionFixture::EXP_B_ID => MutualExclusionFixture::EXP_B_VARIATION_ID }
      )

      second = em.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(second).to be_a(ConvertSdk::BucketedVariation)
      expect(second.id).to eq(MutualExclusionFixture::EXP_B_VARIATION_ID)
    end
  end

  describe "AC3 — store persistence across two independent DataManager/ExperienceManager " \
           "instances (row 8), via the shipped RedisStore contract" do
    # A single shared persistent store (the shipped RedisStore wrapping a
    # hand-rolled FakeRedis — spec/support/store_helpers.rb — so the suite
    # still runs with the `redis` gem uninstalled), wrapped in ONE
    # DataStoreManager (`shared_dsm`) that is read by two separate
    # DataManager/ExperienceManager instances. Unlike MemoryStore, this
    # exercises the REAL JSON serialize/deserialize round-trip the resolver's
    # stored-bucketing read depends on cross-process, and the shared store is
    # what makes cross-context persistence observable.
    let(:shared_redis) { ConvertSdk::Stores::RedisStore.new(redis: FakeRedis.new) }
    let(:shared_dsm) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: shared_redis) }

    it "a decision persisted by context 1 excludes the same visitor from exp-b in a FRESH " \
       "context 2 reading the same persistent store" do
      _, em1 = build(data_store_manager: shared_dsm)
      visitor = "visitor-cross-context"
      a_decision = em1.select_variation(visitor, MutualExclusionFixture::EXP_A_KEY, attrs)
      expect(a_decision).to be_a(ConvertSdk::BucketedVariation)

      _, em2 = build(data_store_manager: shared_dsm) # a FRESH DataManager/ExperienceManager pair
      b_decision = em2.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end

    it "a DIFFERENT visitor who never ran exp-a via context 1 still buckets into exp-b " \
       "normally when read through context 2 (proves per-visitor independence, not a global " \
       "exclusion)" do
      _, em1 = build(data_store_manager: shared_dsm)
      em1.select_variation("visitor-cross-context", MutualExclusionFixture::EXP_A_KEY, attrs)

      _, em2 = build(data_store_manager: shared_dsm)
      other_visitor = "visitor-never-ran-a-cross-context"
      b_decision = em2.select_variation(other_visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(b_decision).to be_a(ConvertSdk::BucketedVariation)
      expect(b_decision.id).to eq(MutualExclusionFixture::EXP_B_VARIATION_ID)
    end
  end

  describe "AC5 — read-only: zero target bucketing, zero store writes, zero track/event " \
           "enqueue while evaluating the exclusion rule (safety invariant)" do
    it "never invokes either bucketing method and never merges visitor data while " \
       "evaluating (and failing) exp-b's exclusion audience" do
      _, em = build
      visitor = "visitor-ac5"
      em.select_variation(visitor, MutualExclusionFixture::EXP_A_KEY, attrs) # precondition: ran A

      expect(bucketing_manager).not_to receive(:bucket_for_visitor)
      expect(bucketing_manager).not_to receive(:bucket_for_visitor_anchored)
      expect(dsm).not_to receive(:merge_visitor_data)

      b_decision = em.select_variation(visitor, MutualExclusionFixture::EXP_B_KEY, attrs)
      expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end

    it "fires no lifecycle event and enqueues no track event at the Context level when " \
       "run_experience is excluded" do
      dm, em = build
      event_manager = ConvertSdk::EventManager.new(log_manager: log_manager)
      api_manager = double("api_manager") # strict: any call other than the allowed enqueue below fails the example
      allow(api_manager).to receive(:enqueue)

      context = ConvertSdk::Context.new(
        visitor_id: "visitor-ac5-context", data_manager: dm, data_store_manager: dsm,
        event_manager: event_manager, log_manager: log_manager, config: config,
        experience_manager: em, api_manager: api_manager
      )

      context.run_experience(MutualExclusionFixture::EXP_A_KEY) # precondition: ran A (allowed to enqueue)

      expect(event_manager).not_to receive(:fire)
      expect(api_manager).not_to receive(:enqueue)

      b_decision = context.run_experience(MutualExclusionFixture::EXP_B_KEY)
      expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
    end
  end

  describe "AC6 — combination semantics: the exclusion rule combined with a generic " \
           "(attribute) rule under ALL and ANY, exactly like existing rules" do
    describe "under ALL (AND) — both the generic leaf and the resolver leaf must match" do
      let(:exp_b_rules) do
        MutualExclusionFixture.rule_tree(
          [
            MutualExclusionFixture.generic_leaf(key: "country", value: "US"),
            MutualExclusionFixture.exclusion_leaf(target_key: MutualExclusionFixture::EXP_A_KEY, negated: false)
          ], mode: :all
        )
      end
      let(:config_hash) { MutualExclusionFixture.config(exp_b_rules: exp_b_rules) }

      it "matches — country=US AND bucketed into exp-a" do
        _, em = build(config_hash)
        visitor = "visitor-ac6-all-match"
        em.select_variation(visitor, MutualExclusionFixture::EXP_A_KEY, attrs)

        b_decision = em.select_variation(
          visitor, MutualExclusionFixture::EXP_B_KEY, attrs(visitor_properties: { "country" => "US" })
        )
        expect(b_decision).to be_a(ConvertSdk::BucketedVariation)
      end

      it "fails — country=US but NEVER bucketed into exp-a" do
        _, em = build(config_hash)
        b_decision = em.select_variation(
          "visitor-ac6-all-nomatch", MutualExclusionFixture::EXP_B_KEY,
          attrs(visitor_properties: { "country" => "US" })
        )
        expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
      end
    end

    describe "under ANY (OR_WHEN) — either the generic leaf or the resolver leaf matching suffices" do
      let(:exp_b_rules) do
        MutualExclusionFixture.rule_tree(
          [
            MutualExclusionFixture.generic_leaf(key: "country", value: "GB"),
            MutualExclusionFixture.exclusion_leaf(target_key: MutualExclusionFixture::EXP_A_KEY, negated: false)
          ], mode: :any
        )
      end
      let(:config_hash) { MutualExclusionFixture.config(exp_b_rules: exp_b_rules) }

      it "matches — country=US (generic leaf fails) but bucketed into exp-a" do
        _, em = build(config_hash)
        visitor = "visitor-ac6-any-match"
        em.select_variation(visitor, MutualExclusionFixture::EXP_A_KEY, attrs)

        b_decision = em.select_variation(
          visitor, MutualExclusionFixture::EXP_B_KEY, attrs(visitor_properties: { "country" => "US" })
        )
        expect(b_decision).to be_a(ConvertSdk::BucketedVariation)
      end

      it "fails — country=US (generic leaf fails) and never bucketed into exp-a" do
        _, em = build(config_hash)
        b_decision = em.select_variation(
          "visitor-ac6-any-nomatch", MutualExclusionFixture::EXP_B_KEY,
          attrs(visitor_properties: { "country" => "US" })
        )
        expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
      end
    end
  end

  describe "AC8 — unknown target (exp-zz, absent from config): warning naming the key + " \
           "the exclusion dissolves" do
    def warn_messages
      sink.entries.filter_map { |level, msg| msg if level == :warn }
    end

    describe "negated: false (row 6 — dissolved match is false; still excluded)" do
      let(:config_hash) do
        MutualExclusionFixture.config(
          exp_b_rules: MutualExclusionFixture.rule_tree(
            [MutualExclusionFixture.exclusion_leaf(target_key: MutualExclusionFixture::EXP_ZZ_KEY, negated: false)],
            mode: :all
          )
        )
      end

      it "excluded, and logs a warning naming exp-zz (unresolved target)" do
        _, em = build(config_hash)
        b_decision = em.select_variation("visitor-ac8-row6", MutualExclusionFixture::EXP_B_KEY, attrs)

        expect(b_decision).to be(ConvertSdk::RuleError::NO_DATA_FOUND)
        expect(warn_messages.any? { |m| m.include?(MutualExclusionFixture::EXP_ZZ_KEY) })
          .to be(true), "expected a warning naming exp-zz, got: #{warn_messages.inspect}"
      end
    end

    describe "negated: true (row 7 — dissolved match is true; buckets normally)" do
      let(:config_hash) do
        MutualExclusionFixture.config(
          exp_b_rules: MutualExclusionFixture.rule_tree(
            [MutualExclusionFixture.exclusion_leaf(target_key: MutualExclusionFixture::EXP_ZZ_KEY, negated: true)],
            mode: :all
          )
        )
      end

      it "buckets normally into exp-b AND logs a warning naming exp-zz (unresolved target)" do
        _, em = build(config_hash)
        b_decision = em.select_variation("visitor-ac8-row7", MutualExclusionFixture::EXP_B_KEY, attrs)

        expect(b_decision).to be_a(ConvertSdk::BucketedVariation)
        expect(warn_messages.any? { |m| m.include?(MutualExclusionFixture::EXP_ZZ_KEY) })
          .to be(true), "expected a warning naming exp-zz, got: #{warn_messages.inspect}"
      end
    end
  end
end
