# frozen_string_literal: true

require "spec_helper"

# Unit spec for the OR->AND->OR_WHEN rule walk.
#
# +ConvertSdk::RuleManager+ mirrors the JS SDK +packages/rules/src/rule-manager.ts+
# walk EXACTLY: an outer OR of AND-groups of OR_WHEN leaf-rule lists, with the JS
# short-circuit order preserved. JS is the only truth (PHP is quarantined).
#
# The two safety invariants under test:
#   * FR22 — empty NEVER matches everyone: every empty/missing block shape returns
#     false AND logs RULE_NOT_VALID at warn level (rule-manager.ts:148/214/249/359).
#   * RuleError propagation — a leaf RuleError sentinel propagates up the walk
#     (AND: `return match if match != true`; OR/OR_WHEN: `return match if match
#     != false`), exactly as JS does.
#
# Duplication discipline: the empty/missing-block shapes are exercised through a
# single tabular runner; walk-structure scenarios share builder helpers so no
# rule literal is copy-pasted across examples.
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

  # A single OR_WHEN leaf rule. `match_type` is a WIRE operator string.
  def leaf(key:, value:, match_type: "equals", negated: false)
    { "rule_type" => "generic_key_value",
      "matching" => { "match_type" => match_type, "negated" => negated },
      "value" => value, "key" => key }
  end

  # Wrap leaves in OR_WHEN -> AND -> OR. `and_groups` is an array of arrays of
  # leaves; each inner array is one AND group, each leaf its own OR_WHEN list.
  def rule_set(*and_groups)
    { "OR" => and_groups.map { |leaves| { "AND" => leaves.map { |l| { "OR_WHEN" => [l] } } } } }
  end

  # The warn messages that carry the RULE_NOT_VALID token.
  def rule_not_valid_warns
    sink.entries.select { |level, msg| level == :warn && msg.include?(described_class::RULE_NOT_VALID) }
  end

  describe "#is_rule_matched — single OR_WHEN leaf" do
    it "returns true when the leaf operator matches" do
      rs = rule_set([leaf(key: "country", value: "US")])
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(true)
    end

    it "returns false when the leaf operator does not match" do
      rs = rule_set([leaf(key: "country", value: "US")])
      expect(manager.is_rule_matched({ "country" => "GB" }, rs)).to be(false)
    end

    it "returns false when the data key is absent (no match, FR22)" do
      rs = rule_set([leaf(key: "country", value: "US")])
      expect(manager.is_rule_matched({ "browser" => "chrome" }, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — AND semantics (ALL must match)" do
    let(:data) { { "country" => "US", "browser" => "chrome", "device" => "mobile" } }

    it "is true when every AND leaf matches" do
      rs = rule_set([leaf(key: "country", value: "US"), leaf(key: "browser", value: "chrome")])
      expect(manager.is_rule_matched(data, rs)).to be(true)
    end

    it "is false when one AND leaf fails (partial match)" do
      rs = rule_set([leaf(key: "country", value: "US"), leaf(key: "device", value: "desktop")])
      expect(manager.is_rule_matched(data, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — OR semantics (ANY group matches)" do
    let(:data) { { "country" => "GB" } }

    it "is true when a later OR group matches after an earlier one fails" do
      rs = rule_set([leaf(key: "country", value: "US")], [leaf(key: "country", value: "GB")])
      expect(manager.is_rule_matched(data, rs)).to be(true)
    end

    it "is false when no OR group matches" do
      rs = rule_set([leaf(key: "country", value: "US")], [leaf(key: "country", value: "FR")])
      expect(manager.is_rule_matched(data, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — negation (rule.matching.negated)" do
    it "matches when a negated equals does NOT equal" do
      rs = rule_set([leaf(key: "country", value: "GB", negated: true)])
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(true)
    end

    it "does not match when a negated equals DOES equal" do
      rs = rule_set([leaf(key: "country", value: "US", negated: true)])
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — existence operators on absent keys (undefined-fallback)" do
    it "exists on an absent key is false (evaluated against UNDEFINED)" do
      rs = rule_set([leaf(key: "country", value: "", match_type: "exists")])
      expect(manager.is_rule_matched({ "browser" => "chrome" }, rs)).to be(false)
    end

    # The wire absence operator is doesNotExist (CookieMatchingOptions enum,
    # types.gen.ts:626-627 has only EXISTS/DOES_NOT_EXIST). The JS undefined-
    # fallback whitelist (rule-manager.ts:324-326) therefore covers exists and
    # doesNotExist ONLY — a raw `not_exists` match_type gets NO fallback and so
    # returns false on an absent key (key-not-found path). Faithful to JS.
    it "not_exists on an absent key is false (no fallback; not in CookieMatchingOptions)" do
      rs = rule_set([leaf(key: "country", value: "", match_type: "not_exists")])
      expect(manager.is_rule_matched({ "browser" => "chrome" }, rs)).to be(false)
    end

    it "doesNotExist on an absent key is true" do
      rs = rule_set([leaf(key: "country", value: "", match_type: "doesNotExist")])
      expect(manager.is_rule_matched({ "browser" => "chrome" }, rs)).to be(true)
    end

    it "exists on a present non-empty key is true" do
      rs = rule_set([leaf(key: "country", value: "", match_type: "exists")])
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(true)
    end

    it "exists on a present nil (JS null) key is false" do
      rs = rule_set([leaf(key: "country", value: "", match_type: "exists")])
      expect(manager.is_rule_matched({ "country" => nil }, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — keys_case_sensitive" do
    let(:data) { { "COUNTRY" => "US" } }
    let(:rs) { rule_set([leaf(key: "country", value: "US")]) }

    it "does NOT match a differently-cased key when case-sensitive (JS default true)" do
      cs_manager = described_class.new(
        config: ConvertSdk::Config.new(data: {}, keys_case_sensitive: true),
        comparisons: ConvertSdk::Comparisons, log_manager: log_manager
      )
      expect(cs_manager.is_rule_matched(data, rs)).to be(false)
    end

    it "matches a differently-cased key when case-insensitive" do
      ci_manager = described_class.new(
        config: ConvertSdk::Config.new(data: {}, keys_case_sensitive: false),
        comparisons: ConvertSdk::Comparisons, log_manager: log_manager
      )
      expect(ci_manager.is_rule_matched(data, rs)).to be(true)
    end
  end

  describe "#is_rule_matched — empty/missing block shapes (FR22: empty never matches)" do
    # Each row is [description, ruleSet] — all must return false AND warn
    # RULE_NOT_VALID. Tabular so adding a shape is one row.
    [
      ["empty top-level ruleSet", {}],
      ["OR present but empty", { "OR" => [] }],
      ["missing OR key", { "FOO" => [] }],
      ["AND present but empty", { "OR" => [{ "AND" => [] }] }],
      ["missing AND key inside OR group", { "OR" => [{ "FOO" => [] }] }],
      ["OR_WHEN present but empty", { "OR" => [{ "AND" => [{ "OR_WHEN" => [] }] }] }],
      ["missing OR_WHEN key", { "OR" => [{ "AND" => [{ "FOO" => [] }] }] }]
    ].each do |description, rule_set_shape|
      it "#{description} -> false + RULE_NOT_VALID warn" do
        expect(manager.is_rule_matched({ "country" => "US" }, rule_set_shape)).to be(false)
        expect(rule_not_valid_warns).not_to be_empty
      end
    end
  end

  describe "#is_rule_matched — invalid leaf rule shapes -> RULE_NOT_VALID" do
    # Wrap a single (possibly invalid) leaf hash in the OR/AND/OR_WHEN nest.
    def self.wrap_leaf(leaf_hash)
      { "OR" => [{ "AND" => [{ "OR_WHEN" => [leaf_hash] }] }] }
    end

    [
      ["missing matching", wrap_leaf({ "key" => "country", "value" => "US" })],
      ["missing value for non-existence op",
       wrap_leaf({ "matching" => { "match_type" => "equals", "negated" => false }, "key" => "country" })]
    ].each do |description, rule_set_shape|
      it "#{description} -> false + RULE_NOT_VALID warn" do
        expect(manager.is_rule_matched({ "country" => "US" }, rule_set_shape)).to be(false)
        expect(rule_not_valid_warns).not_to be_empty
      end
    end

    it "an existence leaf is valid WITHOUT a value field" do
      rs = { "OR" => [{ "AND" => [{ "OR_WHEN" => [
        { "matching" => { "match_type" => "exists", "negated" => false }, "key" => "country" }
      ] }] }] }
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(true)
    end
  end

  describe "#is_rule_matched — unsupported operator" do
    it "warns and returns false for an unknown match_type" do
      rs = rule_set([leaf(key: "country", value: "US", match_type: "noSuchOperator")])
      expect(manager.is_rule_matched({ "country" => "US" }, rs)).to be(false)
    end
  end

  describe "#is_rule_matched — RuleError propagation" do
    # A leaf that returns a RuleError sentinel must propagate up unchanged
    # through OR_WHEN -> AND -> OR (JS: AND `return match if match != true`,
    # OR/OR_WHEN `return match if match != false`). A stub comparison processor
    # returns the sentinel for a sentinel-triggering value.
    let(:sentinel_processor) do
      Module.new do
        def self.dispatch = { "needData" => :need_data }
        def self.need_data(_value, _test, _neg) = ConvertSdk::RuleError::NEED_MORE_DATA
      end
    end
    let(:sentinel_manager) do
      described_class.new(config: config, comparisons: sentinel_processor, log_manager: log_manager)
    end

    it "propagates NEED_MORE_DATA up a single OR_WHEN/AND/OR chain" do
      rs = rule_set([leaf(key: "country", value: "X", match_type: "needData")])
      expect(sentinel_manager.is_rule_matched({ "country" => "US" }, rs))
        .to be(ConvertSdk::RuleError::NEED_MORE_DATA)
    end

    it "propagates NEED_MORE_DATA out of an AND group (non-true short-circuit)" do
      rs = { "OR" => [{ "AND" => [
        { "OR_WHEN" => [leaf(key: "country", value: "X", match_type: "needData")] }
      ] }] }
      expect(sentinel_manager.is_rule_matched({ "country" => "US" }, rs))
        .to be(ConvertSdk::RuleError::NEED_MORE_DATA)
    end
  end

  describe "#is_rule_matched — debug outcome logging for valid rules" do
    it "logs at debug (not warn) for a valid matching rule" do
      rs = rule_set([leaf(key: "country", value: "US")])
      manager.is_rule_matched({ "country" => "US" }, rs)
      expect(rule_not_valid_warns).to be_empty
      expect(sink.entries.map(&:first)).to include(:debug)
    end
  end
end
