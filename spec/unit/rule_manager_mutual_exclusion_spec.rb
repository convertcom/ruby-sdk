# frozen_string_literal: true

require "spec_helper"

# qs-09 (RB-1) — RuleManager support for the new +bucketed_into_experience_key+
# audience rule (declarative mutual exclusion on fullstack).
#
# Spec of record: _bmad-output/implementation-artifacts/2026-06-05-convert-ruby-sdk/
#   qs-09-mutual-exclusion-rule.md
#
# Acceptance criteria exercised in THIS file (RuleManager-unit scope only):
#   - AC1 — the 8-row cross-SDK fixture, table-driven from a single constant.
#   - AC4 — structurally covered: every example below passes `{}` visitor data.
#   - AC6 — combines with a generic rule under ALL (AND) and ANY (OR_WHEN)
#     exactly like existing rules.
#   - AC7 — generic-rule regression lock: the walk signature gaining a
#     `resolver:` parameter must not disturb the 3 existing generic rule types,
#     with AND without a resolver injected.
#   - AC8 — unknown-target warning (rows 6/7), asserted at the RuleManager
#     unit-test level via the injected resolver's three-state return (see the
#     resolver-interface decision below).
#   - AC5 (PARTIAL) — proves RuleManager itself never dispatches through
#     `@comparisons` for this rule_type (`match_type` is genuinely vestigial,
#     never consulted). The FULL AC5 guarantee (no bucketing of the target, no
#     store writes, no tracking events) is a DataManager/Context-level concern
#     and out of scope here.
#
# Explicitly OUT OF SCOPE for this file / this task (RuleManager-unit scope
# only; DataManager/Context wiring — RB-2, merged — is exercised in
# spec/unit/data_manager_mutual_exclusion_spec.rb):
#   - AC2 (end-to-end Context#run_experience exclusion across two experiences)
#   - AC3 (cross-process store persistence — the resolver's OWN correctness,
#     backed by a real/faked store, is a DataManager-level concern; here we
#     only prove RuleManager calls whatever resolver it is given and applies
#     negation/warning per the contract)
#   - AC9 (RBS/steep signatures for the new `resolver:` keyword) — tracked and
#     shipped separately (sig/convert_sdk/rule_manager.rbs); not exercised by
#     this spec file directly.
#
# ## Resolver interface contract (DESIGN DECISION — the qs-09 spec is silent on
# the exact resolver shape; documented here so DataManager's resolver (RB-2,
# merged) implements EXACTLY this, and so this file's fakes are legible in
# isolation):
#
#     resolver = ->(target_experience_key) { true | false | nil }
#
#   - `true` / `false` — the target experience key IS present in the served
#     config; this is `bucketed_raw` per the qs-09 resolution algorithm
#     (whether the visitor's stored bucketing map — in-memory merged with the
#     `store:` — contains an entry for that experience's id).
#   - `nil`            — the target experience key could NOT be resolved
#     against the served config (unknown/absent, rows 6/7). RuleManager treats
#     this exactly like `bucketed_raw = false` for the match computation, but
#     ADDITIONALLY logs a warning naming the unresolved key (AC8) — which a
#     plain known-`false` return (rows 1/5) must NOT do. A two-state
#     (`true`/`false`) resolver interface cannot distinguish "known target,
#     not yet bucketed" from "unknown target" without RuleManager carrying a
#     SEPARATE knowledge of which keys are valid experience keys; three-state
#     (`nil` for "unknown") keeps the resolver a single pure function of the
#     target key and keeps AC8 assertable at this unit level without an extra
#     collaborator. See the decision-log entry in
#     work/2026-07-15-ruby-sdk-mutual-exclusion/decision-log.md for the
#     alternative considered and rejected.
#
# `is_rule_matched` / `process_and` / `process_or_when` / `process_rule_item`
# all gain an optional trailing `resolver:` keyword (default `nil`) threaded
# down UNCHANGED through the walk, so the new leaf is evaluated IN PLACE inside
# the OR/AND/OR_WHEN nesting (required for the ALL/ANY combination under AC6 —
# NOT a pre-pass over the tree).
#
# When NO resolver is injected at all (legacy call sites that predate this
# feature) and a `bucketed_into_experience_key` leaf is encountered,
# RuleManager falls closed to plain `false` WITHOUT applying negation —
# mirrors the JS fail-closed-on-unresolvable behavior
# (javascript-sdk/packages/rules/src/rule-manager.ts:299-364) for the
# "capability entirely absent" case. This is DIFFERENT from the "resolver
# present but target unknown" case (rows 6/7 above), which DOES apply
# negation on top of the false `bucketed_raw`.
#
# `RuleManager#is_rule_matched` accepts the `resolver:` keyword (default
# `nil`, rule_manager.rb:78), so every MUTUAL_EXCLUSION_FIXTURE-driven example
# below exercises the resolver-backed match/negation/warning contract
# end-to-end. The two "no resolver injected" examples below exercise the
# fail-closed fallback described above: a `bucketed_into_experience_key` leaf
# falls through to false-with-negation-unapplied when no resolver is threaded
# at all.

# AC1 — the inline cross-SDK fixture (qs-09 table), byte-identical in intent to
# the sibling SDKs' specs. `resolver_return` encodes what the injected resolver
# reports for the row's target key (see the interface contract above):
# `true`/`false` for a KNOWN target's `bucketed_raw`, `nil` for an UNKNOWN
# target.
#
# Row 8 is modeled EXPLICITLY even though it is IDENTICAL to row 4 at this
# unit-test level: the qs-09 table's row 8 distinguishes "the decision lives
# only in the persistent store, not in-memory" — a distinction the
# DataManager-level visitor-state merge resolves BEFORE RuleManager ever sees
# it. By the time RuleManager calls the injected resolver, the resolver is
# already a pure boolean function of the target key; RuleManager cannot
# observe (and must not care) whether that boolean came from memory or the
# store. So row 8's fake resolver returns `true` — same as row 4 — and its
# assertion is intentionally the same shape as row 4's. This is NOT an
# accidental duplicate: it documents that store-vs-memory is invisible at this
# layer, and the real row-8 coverage (proving the store path feeds the
# resolver correctly) belongs to a later DataManager/Context-level task.
MUTUAL_EXCLUSION_FIXTURE = [
  { row: 1, target: "exp-a", negated: false, resolver_return: false, expected: false, warn_key: nil },
  { row: 2, target: "exp-a", negated: true, resolver_return: false, expected: true, warn_key: nil },
  { row: 3, target: "exp-a", negated: false, resolver_return: true, expected: true, warn_key: nil },
  { row: 4, target: "exp-a", negated: true, resolver_return: true, expected: false, warn_key: nil },
  { row: 5, target: "exp-a", negated: true, resolver_return: false, expected: true, warn_key: nil },
  { row: 6, target: "exp-zz", negated: false, resolver_return: nil, expected: false, warn_key: "exp-zz" },
  { row: 7, target: "exp-zz", negated: true, resolver_return: nil, expected: true, warn_key: "exp-zz" },
  { row: 8, target: "exp-a", negated: true, resolver_return: true, expected: false, warn_key: nil,
    note: "store-only decision (qs-09 row 8) — identical to row 4 at the RuleManager-unit level; " \
          "see MUTUAL_EXCLUSION_FIXTURE comment above" }
].freeze

RSpec.describe ConvertSdk::RuleManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) do
    ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
  end
  let(:config) { ConvertSdk::Config.new(data: {}) }
  let(:manager) do
    described_class.new(config: config, comparisons: ConvertSdk::Comparisons, log_manager: log_manager)
  end

  # --- builder helpers (kill duplication of rule literals) ---

  # A single `bucketed_into_experience_key` leaf, per the qs-09 contract shape.
  # Deliberately carries NO `key` field — the rule_type is resolved against
  # SDK-stored visitor bucketing state, not a caller-passed attribute.
  def mutual_exclusion_leaf(target_key:, negated:)
    { "rule_type" => "bucketed_into_experience_key",
      "matching" => { "match_type" => "equals", "negated" => negated },
      "value" => target_key }
  end

  # A single generic OR_WHEN leaf rule (unchanged from the existing generic
  # rule shape) — used for the AC6/AC7 combination + regression examples.
  def generic_leaf(key:, value:, negated: false)
    { "rule_type" => "generic_key_value",
      "matching" => { "match_type" => "equals", "negated" => negated },
      "value" => value, "key" => key }
  end

  # Wrap a single leaf in the minimal OR -> AND -> OR_WHEN nest.
  def wrap_single_leaf(leaf_hash)
    { "OR" => [{ "AND" => [{ "OR_WHEN" => [leaf_hash] }] }] }
  end

  # The captured warn message strings only (independent of level filtering
  # elsewhere in this file).
  def warn_messages
    sink.entries.filter_map { |level, msg| msg if level == :warn }
  end

  describe "#is_rule_matched — bucketed_into_experience_key (AC1 fixture, AC4 zero-input, AC8 unknown-target warn)" do
    MUTUAL_EXCLUSION_FIXTURE.each do |row|
      it "row #{row[:row]}: target=#{row[:target].inspect} negated=#{row[:negated]} " \
         "resolver_return=#{row[:resolver_return].inspect} -> matched=#{row[:expected]}" do
        resolver = ->(_target_key) { row[:resolver_return] }
        rs = wrap_single_leaf(mutual_exclusion_leaf(target_key: row[:target], negated: row[:negated]))

        # AC4: empty visitor attributes throughout — zero new application inputs.
        result = manager.is_rule_matched({}, rs, nil, resolver: resolver)

        expect(result).to be(row[:expected])

        if row[:warn_key]
          expect(warn_messages.any? { |m| m.include?(row[:warn_key]) })
            .to be(true), "expected a warning naming #{row[:warn_key].inspect}, got: #{warn_messages.inspect}"
        else
          expect(warn_messages.none? { |m| m.include?(row[:target]) }).to be(true)
        end
      end
    end
  end

  describe "#is_rule_matched — bucketed_into_experience_key combined with a generic rule (AC6: ALL / ANY)" do
    it "under ALL (AND) — matches when the generic leaf AND the resolver leaf both match" do
      resolver = ->(_key) { true }
      rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [generic_leaf(key: "country", value: "US")] },
        { "OR_WHEN" => [mutual_exclusion_leaf(target_key: "exp-a", negated: false)] }
      ] }] }
      expect(manager.is_rule_matched({ "country" => "US" }, rs, nil, resolver: resolver)).to be(true)
    end

    it "under ALL (AND) — fails when the generic leaf matches but the resolver leaf does not" do
      resolver = ->(_key) { false }
      rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [generic_leaf(key: "country", value: "US")] },
        { "OR_WHEN" => [mutual_exclusion_leaf(target_key: "exp-a", negated: false)] }
      ] }] }
      expect(manager.is_rule_matched({ "country" => "US" }, rs, nil, resolver: resolver)).to be(false)
    end

    it "under ANY (OR_WHEN) — matches when only the resolver leaf matches (generic leaf fails)" do
      resolver = ->(_key) { true }
      rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [
          generic_leaf(key: "country", value: "GB"),
          mutual_exclusion_leaf(target_key: "exp-a", negated: false)
        ] }
      ] }] }
      expect(manager.is_rule_matched({ "country" => "US" }, rs, nil, resolver: resolver)).to be(true)
    end

    it "under ANY (OR_WHEN) — fails when neither the generic leaf nor the resolver leaf matches" do
      resolver = ->(_key) { false }
      rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [
          generic_leaf(key: "country", value: "GB"),
          mutual_exclusion_leaf(target_key: "exp-a", negated: false)
        ] }
      ] }] }
      expect(manager.is_rule_matched({ "country" => "US" }, rs, nil, resolver: resolver)).to be(false)
    end
  end

  describe "#is_rule_matched — bucketed_into_experience_key never dispatches through the comparison " \
           "processor (AC5 partial: match_type is vestigial)" do
    it "does not call the comparison processor's dispatch for a resolver-backed leaf" do
      resolver = ->(_key) { true }
      spy_comparisons = double("comparisons") # no stubs — ANY call is a failure
      manager_with_spy = described_class.new(config: config, comparisons: spy_comparisons, log_manager: log_manager)
      rs = wrap_single_leaf(mutual_exclusion_leaf(target_key: "exp-a", negated: false))

      expect(spy_comparisons).not_to receive(:dispatch)
      result = manager_with_spy.is_rule_matched({}, rs, nil, resolver: resolver)

      expect(result).to be(true)
    end
  end

  describe "#is_rule_matched — bucketed_into_experience_key with NO resolver injected " \
           "(fail-closed, negation unapplied)" do
    it "returns false when negated: false and no resolver is injected" do
      rs = wrap_single_leaf(mutual_exclusion_leaf(target_key: "exp-a", negated: false))
      expect(manager.is_rule_matched({}, rs)).to be(false)
    end

    it "returns false when negated: true and no resolver is injected (negation NOT applied on the fall-through)" do
      rs = wrap_single_leaf(mutual_exclusion_leaf(target_key: "exp-a", negated: true))
      expect(manager.is_rule_matched({}, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — bucketed_into_experience_key with a malformed `matching` value " \
           "(code-review finding, confidence 78 — FR22 fail-closed, never raise)" do
    # `rule["matching"]` is NOT validated to be a Hash before `process_rule_item`
    # dispatches a `bucketed_into_experience_key` leaf straight to
    # `process_mutual_exclusion_rule` (it bypasses `valid_rule?` entirely,
    # unlike every generic leaf). A non-Hash, non-nil `matching` (or a missing
    # `matching` key) must fail closed to `false` and must NEVER consult the
    # injected resolver — proven here with a resolver double that WOULD return
    # `true` if it were ever called.
    def never_called_resolver
      lambda do |_target_key|
        raise "resolver must never be called for a malformed `matching` leaf"
      end
    end

    it "returns false (never raises) when `matching` is a non-Hash, non-nil value" do
      rule = { "rule_type" => "bucketed_into_experience_key", "matching" => "equals", "value" => "exp-a" }
      rs = wrap_single_leaf(rule)

      result = nil
      expect { result = manager.is_rule_matched({}, rs, nil, resolver: never_called_resolver) }.not_to raise_error
      expect(result).to be(false)
    end

    it "returns false (never raises) when the `matching` key is missing entirely" do
      rule = { "rule_type" => "bucketed_into_experience_key", "value" => "exp-a" }
      rs = wrap_single_leaf(rule)

      result = nil
      expect { result = manager.is_rule_matched({}, rs, nil, resolver: never_called_resolver) }.not_to raise_error
      expect(result).to be(false)
    end
  end

  describe "#is_rule_matched — generic-rule regression lock (AC7)" do
    let(:data) { { "country" => "US", "browser" => "chrome" } }
    let(:generic_rs) do
      { "OR" => [{ "AND" => [
        { "OR_WHEN" => [generic_leaf(key: "country", value: "US")] },
        { "OR_WHEN" => [generic_leaf(key: "browser", value: "chrome")] }
      ] }] }
    end

    it "resolves a generic AND tree identically when called WITHOUT a resolver at all" do
      expect(manager.is_rule_matched(data, generic_rs)).to be(true)
    end

    it "resolves a generic AND tree identically when called WITH a resolver injected " \
       "(the resolver must never be invoked for a generic leaf)" do
      resolver = ->(_key) { raise "resolver must never be called for a generic (non-mutual-exclusion) leaf" }
      expect(manager.is_rule_matched(data, generic_rs, nil, resolver: resolver)).to be(true)
    end

    it "a partial-match generic AND tree still fails identically with a resolver injected but unused" do
      resolver = ->(_key) { raise "resolver must never be called for a generic (non-mutual-exclusion) leaf" }
      failing_rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [generic_leaf(key: "country", value: "US")] },
        { "OR_WHEN" => [generic_leaf(key: "browser", value: "firefox")] }
      ] }] }
      expect(manager.is_rule_matched(data, failing_rs, nil, resolver: resolver)).to be(false)
    end
  end
end
