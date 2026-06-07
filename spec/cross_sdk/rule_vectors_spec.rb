# frozen_string_literal: true

require "spec_helper"
require "json"

# Cross-SDK rule-engine parity suite — the release-blocking proof that the Ruby
# rule engine (operators + OR->AND->OR_WHEN walk) decides audience targeting
# byte-identically to the JS SDK. Runs in the independent parity CI job
# (everything under spec/cross_sdk; wired in Story 1.2).
#
# Two data-driven sources (no copy-paste assertion blocks — one example per JSON
# case via shared iterators):
#
#   1. VENDORED GOLDENS — spec/fixtures/cross_sdk/rule-test-vectors.json (copied
#      from the PHP CrossSdk suite in Story 1.2). Two sections:
#        * comparison_operators — {category, method, cases:[{value, testAgainst,
#          negation, expected}]} exercised through Comparisons.
#        * rule_evaluation — {category, data, ruleSet, expected, keysCaseSensitive?}
#          exercised through the full RuleManager walk.
#
#   2. RUBY EXTENSIONS — spec/fixtures/cross_sdk/rule-test-vectors-ruby-extensions.json.
#      The existence operators (exists/not_exists/doesNotExist) and the JS
#      undefined(absent) vs null(present-nil) distinction. ADDED separately,
#      sourced from JS semantics, because PHP lacks the existence operators (a
#      disk-verified gap) so the vendored goldens have no existence cases.
#
# JS-DIVERGENCE OVERRIDE (the one place the vendored golden encodes PHP, not JS):
#   The vendored isIn case {value:"A", testAgainst:"a|b|c", expected:true,
#   note:"case-insensitive"} reflects PHP's Comparisons.php:164-166, which
#   lowercases the VALUES side. JS comparisons.ts:95-99 does NOT lowercase the
#   values side (only testAgainst, ts:106-108) — so isIn("A","a|b|c") is FALSE in
#   JS. JS is the only truth (the story quarantines PHP), so this single case is
#   OVERRIDDEN to the JS-correct expectation here. The vendored JSON is left
#   untouched (story constraint). See JS_DIVERGENCE_OVERRIDES below.
RSpec.describe "Cross-SDK rule-engine parity" do
  fixtures_dir = File.expand_path("../fixtures/cross_sdk", __dir__)
  vendored = JSON.parse(File.read(File.join(fixtures_dir, "rule-test-vectors.json")))
  extensions = JSON.parse(File.read(File.join(fixtures_dir, "rule-test-vectors-ruby-extensions.json")))

  # The single JS-divergent vendored case: key it on (method, value, testAgainst,
  # negation) -> the JS-correct expectation. Any matching case is asserted against
  # this override instead of the (PHP-derived) vendored `expected`. A local (not a
  # constant) so it stays scoped to this example group.
  js_divergence_overrides = {
    ["isIn", "A", "a|b|c", false] => false
  }.freeze

  define_singleton_method(:override_for) do |method, kase|
    js_divergence_overrides[[method, kase["value"], kase["testAgainst"], kase["negation"] || false]]
  end

  # --- comparison_operators: exercised directly through Comparisons.dispatch ---
  shared_examples "an operator vector group" do |group|
    method = group["method"]
    ruby_method = ConvertSdk::Comparisons.dispatch.fetch(method)

    describe "#{group["category"]} (wire op #{method.inspect} -> ##{ruby_method})" do
      group["cases"].each do |kase|
        override = override_for(method, kase)
        expected = override.nil? ? kase["expected"] : override
        suffix = override.nil? ? "" : " [JS-divergence override; vendored says #{kase["expected"]}]"
        it "#{kase["note"]} -> #{expected}#{suffix}" do
          actual = ConvertSdk::Comparisons.public_send(
            ruby_method, kase["value"], kase["testAgainst"], kase["negation"] || false
          )
          expect(actual).to be(expected)
        end
      end
    end
  end

  describe "vendored comparison_operators" do
    vendored["comparison_operators"].each do |group|
      include_examples "an operator vector group", group
    end
  end

  describe "Ruby-extension comparison_operators (existence operators, JS-sourced)" do
    extensions["comparison_operators"].each do |group|
      include_examples "an operator vector group", group
    end
  end

  # --- rule_evaluation: exercised through the full RuleManager walk ---
  shared_examples "a walk vector" do |entry|
    keys_case_sensitive = entry.fetch("keysCaseSensitive", true)
    config = ConvertSdk::Config.new(data: {}, keys_case_sensitive: keys_case_sensitive)
    manager = ConvertSdk::RuleManager.new(
      config: config, comparisons: ConvertSdk::Comparisons,
      log_manager: ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::ERROR)
    )

    it "#{entry["category"]}: #{entry["description"]} -> #{entry["expected"]}" do
      actual = manager.is_rule_matched(entry["data"], entry["ruleSet"])
      expect(actual).to be(entry["expected"])
    end
  end

  describe "vendored rule_evaluation walk" do
    vendored["rule_evaluation"].each do |entry|
      include_examples "a walk vector", entry
    end
  end

  describe "Ruby-extension rule_evaluation walk (existence undefined-fallback, JS-sourced)" do
    extensions["rule_evaluation"].each do |entry|
      include_examples "a walk vector", entry
    end
  end

  # Guards against a truncated/over-trimmed fixture: the vendored counts are the
  # Story 1.2 goldens; the extension counts are this story's additions.
  describe "fixture integrity" do
    it "vendors the expected operator-group and walk-scenario counts" do
      expect(vendored["comparison_operators"].length).to eq(10)
      expect(vendored["rule_evaluation"].length).to eq(12)
    end

    it "adds the Ruby existence extensions without touching the vendored JSON" do
      expect(extensions["comparison_operators"].map { |g| g["method"] })
        .to contain_exactly("exists", "not_exists", "doesNotExist")
      expect(extensions["rule_evaluation"].length).to eq(5)
    end
  end
end
