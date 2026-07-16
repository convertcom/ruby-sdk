# frozen_string_literal: true

# Shared qs-09 mutual-exclusion config builder (RB-2 — DataManager wiring).
#
# Spec of record: _bmad-output/implementation-artifacts/2026-06-05-convert-ruby-sdk/
#   qs-09-mutual-exclusion-rule.md — the inline cross-SDK fixture (exp-a id
#   100111 / var 100901, exp-b id 100222 / var 100902, both a/b_fullstack,
#   active) + AC2..AC8.
#
# Builds the MINIMAL config shape every RB-2 DataManager-level example needs,
# parameterized ONLY on exp-b's audience rule tree (+ the experience-level
# +matching_options+, unused by the current examples but left overridable) so
# every example (AC2/AC3/AC4/AC5/AC6/AC8) shares ONE experience/variation/
# audience shape instead of copy-pasting it per test (kills the Sonar
# new-code-duplication trap across a table of near-identical fixtures).
#
# exp-a is deliberately UNCONDITIONAL (no audience) so every scenario can bucket
# a visitor into it as the "already ran A" precondition without any of its own
# gating interfering with the assertions under test.
module MutualExclusionFixture
  EXP_A_ID = "100111"
  EXP_A_KEY = "exp-a"
  EXP_A_VARIATION_ID = "100901"

  EXP_B_ID = "100222"
  EXP_B_KEY = "exp-b"
  EXP_B_VARIATION_ID = "100902"

  # Deliberately ABSENT from every config built here (AC8 — unknown target).
  EXP_ZZ_KEY = "exp-zz"

  ACCOUNT_ID = "qs09-account"
  PROJECT_ID = "qs09-project"

  AUDIENCE_ID = "900001"

  # A second, INDEPENDENT audience — never combined with the exclusion leaf
  # inside one rule tree (that's the existing intra-audience AC6 coverage
  # above); used only by {#config_two_audiences} to attach TWO separate
  # audiences to exp-b, composed at the EXPERIENCE level via
  # +settings.matching_options.audiences+ (qs-09 AC6, JS SDK PR #416 model).
  GENERIC_AUDIENCE_ID = "900002"

  # The generic audience's match target — an attribute the test visitor either
  # carries (match) or omits (no match).
  GENERIC_MATCH_KEY = "country"
  GENERIC_MATCH_VALUE = "US"

  module_function

  # A single +bucketed_into_experience_key+ leaf (qs-09 rule shape) — no +key+
  # field, resolved against SDK-stored visitor bucketing state, not attributes.
  def exclusion_leaf(target_key:, negated:)
    { "rule_type" => "bucketed_into_experience_key",
      "matching" => { "match_type" => "equals", "negated" => negated },
      "value" => target_key }
  end

  # A generic attribute leaf (unchanged existing rule shape) — for AC6.
  def generic_leaf(key:, value:, negated: false)
    { "rule_type" => "generic_text_key_value",
      "matching" => { "match_type" => "equals", "negated" => negated },
      "key" => key, "value" => value }
  end

  # Wrap leaves under ALL (every leaf its own AND-member — every leaf must
  # match) or ANY (every leaf in one OR_WHEN group — any one leaf wins).
  def rule_tree(leaves, mode: :all)
    case mode
    when :all then { "OR" => [{ "AND" => leaves.map { |leaf| { "OR_WHEN" => [leaf] } } }] }
    when :any then { "OR" => [{ "AND" => [{ "OR_WHEN" => leaves }] }] }
    else raise ArgumentError, "unknown rule_tree mode #{mode.inspect}"
    end
  end

  # One running, 100%-traffic variation — the only shape {DataManager} needs to
  # deterministically bucket every visitor into it (a single bucket spanning the
  # entire hash range).
  def variation(variation_id)
    { "id" => variation_id, "key" => "var-#{variation_id}", "name" => "Variation #{variation_id}",
      "status" => "running", "traffic_allocation" => 100.0 }
  end

  def experience(exp_id:, key:, variation_id:, audience_ids: [], matching_options: "all")
    {
      "id" => exp_id, "key" => key, "name" => key, "type" => "a/b_fullstack", "status" => "active",
      "audiences" => audience_ids,
      "settings" => { "matching_options" => { "audiences" => matching_options } },
      "variations" => [variation(variation_id)]
    }
  end

  def audience(rules, aud_id: AUDIENCE_ID)
    { "id" => aud_id, "name" => "qs-09 exclusion audience", "type" => "transient",
      "status" => "active", "key" => "qs-09-exclusion-audience-#{aud_id}", "rules" => rules }
  end

  # The default exp-b audience: the AC2/AC3/AC4/AC5 baseline scenario — a
  # single negated exclusion rule targeting exp-a under ALL.
  def default_exp_b_rules
    rule_tree([exclusion_leaf(target_key: EXP_A_KEY, negated: true)], mode: :all)
  end

  # The second audience's rule tree for {#config_two_audiences} — a single
  # generic leaf matching {GENERIC_MATCH_KEY}/{GENERIC_MATCH_VALUE}. Kept
  # entirely separate from {#default_exp_b_rules}'s exclusion leaf — the two
  # are composed as TWO AUDIENCES, never as two leaves in one rule tree.
  def generic_audience_rules
    rule_tree([generic_leaf(key: GENERIC_MATCH_KEY, value: GENERIC_MATCH_VALUE)], mode: :all)
  end

  # Shared skeleton for both config builders below — kills the Sonar
  # new-code-duplication trap between the single-audience and two-audience
  # shapes (only the +experiences+/+audiences+ arrays differ).
  def base_config(experiences:, audiences:)
    {
      "account_id" => ACCOUNT_ID,
      "project" => { "id" => PROJECT_ID },
      "experiences" => experiences,
      "audiences" => audiences,
      "features" => [],
      "goals" => [],
      "segments" => []
    }
  end

  # The full flat config: exp-a unconditional, exp-b gated by ONE transient
  # audience built from +exp_b_rules+.
  #
  # @param exp_b_rules [Hash] the audience's OR/AND/OR_WHEN rule tree.
  # @param matching_options [String] exp-b's +settings.matching_options.audiences+
  #   ("all"/"any") — the experience-level audience-combination knob (distinct
  #   from the rule-tree-level ALL/ANY {#rule_tree} builds; there is only ONE
  #   audience attached here, so this rarely changes example outcomes, but is
  #   left overridable for completeness).
  def config(exp_b_rules: default_exp_b_rules, matching_options: "all")
    base_config(
      experiences: [
        experience(exp_id: EXP_A_ID, key: EXP_A_KEY, variation_id: EXP_A_VARIATION_ID),
        experience(exp_id: EXP_B_ID, key: EXP_B_KEY, variation_id: EXP_B_VARIATION_ID,
                   audience_ids: [AUDIENCE_ID], matching_options: matching_options)
      ],
      audiences: [audience(exp_b_rules)]
    )
  end

  # exp-a unconditional, exp-b gated by TWO SEPARATE transient audiences — the
  # default exclusion audience ({#default_exp_b_rules}) plus an independently
  # matchable generic audience ({#generic_audience_rules}) — composed at the
  # EXPERIENCE level via +settings.matching_options.audiences+ (ALL/ANY).
  #
  # This is the qs-09 AC6 audience-level composition model (JS SDK PR #416):
  # distinct from {#config}'s single-audience, intra-audience-tree ALL/ANY
  # coverage above, which combines a generic leaf and the exclusion leaf
  # INSIDE one audience's rule tree instead of as two attached audiences.
  #
  # @param matching_options [String] "all" (every attached audience must
  #   match) or "any" (any one attached audience matching suffices) —
  #   {ConvertSdk::DataManager#all_match_required?}.
  def config_two_audiences(matching_options:)
    base_config(
      experiences: [
        experience(exp_id: EXP_A_ID, key: EXP_A_KEY, variation_id: EXP_A_VARIATION_ID),
        experience(exp_id: EXP_B_ID, key: EXP_B_KEY, variation_id: EXP_B_VARIATION_ID,
                   audience_ids: [AUDIENCE_ID, GENERIC_AUDIENCE_ID], matching_options: matching_options)
      ],
      audiences: [audience(default_exp_b_rules), audience(generic_audience_rules, aud_id: GENERIC_AUDIENCE_ID)]
    )
  end
end
