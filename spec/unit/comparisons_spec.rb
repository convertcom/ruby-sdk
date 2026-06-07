# frozen_string_literal: true

require "spec_helper"

# Unit spec for the 13 rule comparison operators.
#
# +ConvertSdk::Comparisons+ is a pure, stateless operator processor ported
# BYTE-FOR-BYTE from the JS SDK +packages/utils/src/comparisons.ts+ — JS is the
# only truth (the PHP port is missing +exists+/+not_exists+ entirely and is
# quarantined for this story). Every expectation below is DERIVED from the JS
# source semantics at the cited file:line, never from PHP and never invented.
#
# Duplication discipline (the highest-risk spec surface in the gem): every
# operator is exercised through ONE shared tabular runner —
# `[value, test_against, negation] => expected` rows — so adding a case is a
# data row, never a copy-pasted example block.
RSpec.describe ConvertSdk::Comparisons do
  # Shared tabular runner: declare a method symbol and a table of
  # [value, test_against, negation, expected] rows; one `it` per row, asserted
  # against the public operator. This is the only assertion shape in the file.
  def self.operator_truth_table(method, rows)
    describe "##{method}" do
      rows.each do |value, test_against, negation, expected, note|
        label = note || "#{value.inspect} vs #{test_against.inspect} (neg=#{negation})"
        it "#{label} => #{expected}" do
          expect(described_class.public_send(method, value, test_against, negation)).to be(expected)
        end
      end
    end
  end

  # --- equals (comparisons.ts:15) — case-insensitive string equality;
  #     Array -> indexOf membership; non-empty Hash -> key membership. ---
  operator_truth_table(:equals, [
                         ["US", "US", false, true, "exact match"],
                         ["US", "us", false, true, "case-insensitive"],
                         ["us", "US", false, true, "case-insensitive reverse"],
                         ["US", "GB", false, false, "no match"],
                         ["US", "US", true, false, "negated match"],
                         ["US", "GB", true, true, "negated no-match"],
                         ["", "", false, true, "empty strings"],
                         [123, 123, false, true, "numeric coerced to string equal"],
                         [%w[a b c], "b", false, true, "array indexOf match (ts:25-29)"],
                         [%w[a b c], "d", false, false, "array indexOf no match"],
                         [%w[a b c], "d", true, true, "array indexOf negated no-match"],
                         [{ "k1" => 1, "k2" => 2 }, "k1", false, true, "hash key membership (ts:30-34)"],
                         [{ "k1" => 1 }, "missing", false, false, "hash key absent"]
                       ])

  # --- equalsNumber / matches are aliases of equals (comparisons.ts:42-43). ---
  operator_truth_table(:equals_number, [
                         [42, 42, false, true, "equal integers"],
                         [42, 99, false, false, "different integers"],
                         [42, 42, true, false, "negated equal"]
                       ])

  operator_truth_table(:matches, [
                         ["hello", "HELLO", false, true, "case-insensitive match"],
                         ["hello", "world", false, false, "no match"]
                       ])

  # --- less (comparisons.ts:45) — numeric-normalize both via isNumeric/toNumber;
  #     false when normalized types differ; else `<`. ---
  operator_truth_table(:less, [
                         [5, 10, false, true, "int less than"],
                         [10, 5, false, false, "int not less than"],
                         [5, 5, false, false, "equal not less"],
                         [-10, 0, false, true, "negative less than zero"],
                         [5, 10, true, false, "negated less"],
                         [10, 5, true, true, "negated not-less"],
                         ["abc", "xyz", false, true, "string less than (both non-numeric)"],
                         ["xyz", "abc", false, false, "string not less than"],
                         [5, 10.5, false, true, "int vs float both numeric"],
                         ["5", 10, false, true, "numeric string vs int both normalize to number"],
                         [5, "abc", false, false, "number vs non-numeric string -> type mismatch false (ts:52-54)"]
                       ])

  # --- lessEqual (comparisons.ts:58) ---
  operator_truth_table(:less_equal, [
                         [5, 10, false, true, "less than"],
                         [5, 5, false, true, "equal"],
                         [10, 5, false, false, "greater than"],
                         [5, 5, true, false, "negated equal"],
                         [5, "abc", false, false, "type mismatch false"]
                       ])

  # --- contains (comparisons.ts:71) — substring; empty/whitespace testAgainst
  #     -> TRUE (the preserved JS quirk, ts:80-81). ---
  operator_truth_table(:contains, [
                         ["hello world", "world", false, true, "substring present"],
                         ["hello world", "xyz", false, false, "substring absent"],
                         ["HELLO", "ell", false, true, "case-insensitive substring"],
                         ["hello", "", false, true, "empty testAgainst -> true (JS quirk ts:80-81)"],
                         ["hello", "   ", false, true, "whitespace-only testAgainst -> true (JS quirk)"],
                         ["hello world", "world", true, false, "negated substring present"],
                         ["hello", "", true, false, "negated empty quirk"]
                       ])

  # --- isIn (comparisons.ts:89-115) — pipe-split BOTH params; only testAgainst
  #     items lowercased after split (ts:106-108); the `values` items are NOT
  #     lowercased and are compared AS-IS against the lowercased list. This is
  #     verified JS truth and DIVERGES from PHP (Comparisons.php:164-166
  #     lowercases the values side too) — PHP is quarantined, JS wins. ---
  operator_truth_table(:is_in, [
                         ["us", "US|GB|FR", false, true, "lowercase value matches lowercased list"],
                         ["us", "us|gb", false, true, "lowercase value in already-lowercase list"],
                         ["US", "us|gb", false, false, "uppercase value NOT lowercased -> no match (ts:95-99)"],
                         ["A", "a|b|c", false, false,
                          "uppercase value vs lowercased list -> false (JS truth; PHP says true)"],
                         ["DE", "US|GB", false, false, "value not in list (case aside, no lowercase match)"],
                         ["us|gb", "us|gb|fr", false, true, "values pipe-split, first matches lowercased list"],
                         ["de|us", "us|fr", false, true, "values pipe-split, second value matches"],
                         ["a", "a|b|c", true, false, "negated in-list"]
                       ])

  # --- startsWith (comparisons.ts:117) — case-insensitive prefix. ---
  operator_truth_table(:starts_with, [
                         ["hello world", "hello", false, true, "prefix present"],
                         ["hello world", "world", false, false, "not a prefix"],
                         ["HELLO", "he", false, true, "case-insensitive prefix"],
                         ["hello", "hello world", false, false, "testAgainst longer than value"],
                         ["hello", "hello", false, true, "exact equal is a prefix"],
                         ["hello world", "hello", true, false, "negated prefix"]
                       ])

  # --- endsWith (comparisons.ts:130) — case-insensitive suffix. ---
  operator_truth_table(:ends_with, [
                         ["hello world", "world", false, true, "suffix present"],
                         ["hello world", "hello", false, false, "not a suffix"],
                         ["HELLO", "lo", false, true, "case-insensitive suffix"],
                         ["hi", "longer", false, false, "testAgainst longer than value"],
                         ["hello", "hello", false, true, "exact equal is a suffix"],
                         ["hello world", "world", true, false, "negated suffix"]
                       ])

  # --- regexMatches (comparisons.ts:143) — case-insensitive `i` flag. ---
  operator_truth_table(:regex_matches, [
                         ["hello123", "^hello", false, true, "anchored prefix regex"],
                         ["hello", "HELLO", false, true, "case-insensitive regex (i flag ts:150)"],
                         ["abc", "[0-9]+", false, false, "no digit match"],
                         ["abc123", "[0-9]+", false, true, "digit match"],
                         ["hello", "^world", false, false, "anchored no-match"],
                         ["hello", "^hello$", false, true, "full anchor match"],
                         ["hello", "^hello$", true, false, "negated full match"]
                       ])

  # --- exists / not_exists / doesNotExist (comparisons.ts:154-172) ---
  #     value present (non-empty) -> exists true; nil/empty -> exists false.
  describe "existence operators" do
    # exists: value !== undefined && !== null && !== '' (ts:159). Ruby maps
    # both JS undefined AND null to the absence cases below.
    [
      ["US", false, true, "non-empty string exists"],
      ["", false, false, "empty string does NOT exist (ts:159)"],
      [nil, false, false, "nil (JS null) does not exist"],
      [described_class::UNDEFINED, false, false, "UNDEFINED marker (JS undefined) does not exist"],
      [0, false, true, "zero exists (not undefined/null/'')"],
      ["US", true, false, "negated exists"]
    ].each do |value, negation, expected, note|
      it "exists: #{note} => #{expected}" do
        expect(described_class.exists(value, nil, negation)).to be(expected)
      end
    end

    # not_exists is the logical inverse (ts:163-169); doesNotExist aliases it.
    [
      ["US", false, false, "present -> not_exists false"],
      ["", false, true, "empty -> not_exists true"],
      [nil, false, true, "nil -> not_exists true"],
      [described_class::UNDEFINED, false, true, "UNDEFINED -> not_exists true"]
    ].each do |value, negation, expected, note|
      it "not_exists: #{note} => #{expected}" do
        expect(described_class.not_exists(value, nil, negation)).to be(expected)
      end

      it "does_not_exist (alias): #{note} => #{expected}" do
        expect(described_class.does_not_exist(value, nil, negation)).to be(expected)
      end
    end
  end

  # The UNDEFINED marker is a frozen private sentinel distinct from nil, so the
  # walk can model JS `undefined` (key absent) separately from `nil` (JS null).
  describe "UNDEFINED marker" do
    it "is frozen and not equal to nil" do
      expect(described_class::UNDEFINED).to be_frozen
      expect(described_class::UNDEFINED).not_to be_nil
    end
  end

  # The dispatch map exposes the wire/config operator names (camelCase strings)
  # mapped to the snake_case Ruby methods — the two-worlds rule for operators.
  describe ".dispatch" do
    {
      "equals" => :equals, "equalsNumber" => :equals_number, "matches" => :matches,
      "less" => :less, "lessEqual" => :less_equal, "contains" => :contains,
      "isIn" => :is_in, "startsWith" => :starts_with, "endsWith" => :ends_with,
      "regexMatches" => :regex_matches, "exists" => :exists,
      "not_exists" => :not_exists, "doesNotExist" => :does_not_exist
    }.each do |wire, ruby_method|
      it "maps wire operator #{wire.inspect} to ##{ruby_method}" do
        expect(described_class.dispatch[wire]).to eq(ruby_method)
      end
    end

    it "covers exactly the 13 platform operators" do
      expect(described_class.dispatch.keys.length).to eq(13)
    end
  end
end
