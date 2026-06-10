# frozen_string_literal: true

module ConvertSdk
  # The 13 rule comparison operators — the cross-SDK audience-targeting predicate
  # set, ported BYTE-FOR-BYTE from the JS SDK
  # +packages/utils/src/comparisons.ts+.
  #
  # JS is the ONLY truth here. The PHP reference is QUARANTINED for this surface:
  # it ships zero +exists+/+not_exists+ handling (a disk-verified gap) and folds
  # case on the +isIn+ values side (a second divergence), so it must not influence
  # the Ruby contract. Every operator below mirrors its JS body at the cited
  # +comparisons.ts+ line; the goldens in the cross-SDK vector suite are the CI
  # proof of parity.
  #
  # Two-worlds dispatch (operators): the platform sends operator names as
  # camelCase WIRE strings inside the rule JSON (+equalsNumber+, +startsWith+, …).
  # Those strings are config-world identifiers and stay byte-identical; the Ruby
  # methods underneath are snake_case. {dispatch} is the map from the wire name to
  # the Ruby method symbol, consumed by {RuleManager}.
  #
  # The undefined/nil distinction (the subtle one): JS distinguishes +undefined+
  # (a data key is ABSENT) from +null+ (the key is present with a null value).
  # Ruby hashes collapse both to +nil+, so absence is modeled EXPLICITLY with the
  # frozen private {UNDEFINED} marker — {RuleManager} passes {UNDEFINED} for an
  # absent key so the existence operators (and JS-parity need-more-data
  # propagation) behave exactly as JS does with +undefined+. For the existence
  # operators themselves +UNDEFINED+, +nil+, and +""+ are all "does not exist",
  # matching +value !== undefined && value !== null && value !== ''+
  # (+comparisons.ts:159+).
  #
  # Pure and stateless (NFR1): every method is a singleton (+self.+) method with
  # no I/O and no instance state (the same module form as {MurmurHash3}).
  #
  # @api private
  module Comparisons
    # Sentinel for an ABSENT data key, distinct from +nil+ (a present null value).
    # Frozen so it is a stable, comparable singleton. Mirrors JS +undefined+ on
    # the rule-evaluation path.
    UNDEFINED = Object.new.freeze

    # JS +isNumeric+ regex (+string-utils.ts:69+): optional leading minus, then
    # either grouped thousands (+1,234+) or plain digits, with an optional
    # fractional part, or a bare fraction (+.5+).
    NUMERIC_REGEXP = /\A-?(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)\z/

    # Case-insensitive equality. Mirrors +comparisons.ts:15-40+:
    # Array value -> membership of +test_against+; non-empty Hash value -> key
    # membership; otherwise both sides are stringified, lowercased, and compared.
    #
    # @param value [Object] the data value (String, Numeric, Boolean, Array, Hash).
    # @param test_against [Object] the rule's expected value.
    # @param negation [Boolean] when true, the result is inverted.
    # @return [Boolean]
    def self.equals(value, test_against, negation = false)
      return negation_check(value.include?(test_against), negation) if value.is_a?(Array)
      return negation_check(value.key?(test_against.to_s), negation) if value.is_a?(Hash) && !value.empty?

      negation_check(value.to_s.downcase == test_against.to_s.downcase, negation)
    end

    # Alias of {equals} (+comparisons.ts:42+ — +equalsNumber = this.equals+).
    def self.equals_number(value, test_against, negation = false)
      equals(value, test_against, negation)
    end

    # Alias of {equals} (+comparisons.ts:43+ — +matches = this.equals+).
    def self.matches(value, test_against, negation = false)
      equals(value, test_against, negation)
    end

    # Strict less-than over numerically-normalized inputs (+comparisons.ts:45-56+).
    # Numeric-looking strings/numbers normalize to a number; anything else keeps
    # its type. When the normalized types differ the result is +false+ (JS
    # +typeof value !== typeof testAgainst+, ts:52-54).
    #
    # @return [Boolean]
    def self.less(value, test_against, negation = false)
      compare_numeric(value, test_against, negation) { |a, b| a < b }
    end

    # Less-than-or-equal counterpart of {less} (+comparisons.ts:58-69+).
    #
    # @return [Boolean]
    def self.less_equal(value, test_against, negation = false)
      compare_numeric(value, test_against, negation) { |a, b| a <= b }
    end

    # Case-insensitive substring test (+comparisons.ts:71-87+). PRESERVED JS
    # quirk: an empty or whitespace-only +test_against+ returns +true+
    # (ts:80-81) — do not "fix" it.
    #
    # @return [Boolean]
    def self.contains(value, test_against, negation = false)
      value = value.to_s.downcase
      test_against = test_against.to_s.downcase
      return negation_check(true, negation) if test_against.gsub(/\A\s*|\s*\z/, "").empty?

      negation_check(value.include?(test_against), negation)
    end

    # Pipe-split membership (+comparisons.ts:89-115+). BOTH +values+ and a string
    # +test_against+ are split on the +splitter+. Only the +test_against+ items
    # are lowercased after splitting; the +values+ items are compared AS-IS
    # against the lowercased list (so an uppercased value does not match a
    # lowercased entry — exact JS semantics at ts:106-110).
    #
    # @param values [Object] the data value (pipe-joined string or scalar).
    # @param test_against [Object] an Array, or a pipe-joined string to split.
    # @param negation [Boolean]
    # @param splitter [String] the delimiter (default +"|"+).
    # @return [Boolean]
    def self.is_in(values, test_against, negation = false, splitter = "|")
      matched_values = values.to_s.split(splitter, -1).map(&:to_s)
      test_against = test_against.split(splitter, -1) if test_against.is_a?(String)
      unless test_against.is_a?(Array)
        test_against = [] #: Array[untyped]
      end
      test_against = test_against.map { |item| item.to_s.downcase }
      negation_check(matched_values.any? { |item| test_against.include?(item) }, negation)
    end

    # Case-insensitive prefix test (+comparisons.ts:117-128+ — +indexOf === 0+).
    #
    # @return [Boolean]
    def self.starts_with(value, test_against, negation = false)
      value = value.to_s.downcase
      test_against = test_against.to_s.downcase
      negation_check(value.start_with?(test_against), negation)
    end

    # Case-insensitive suffix test (+comparisons.ts:130-141+).
    #
    # @return [Boolean]
    def self.ends_with(value, test_against, negation = false)
      value = value.to_s.downcase
      test_against = test_against.to_s.downcase
      negation_check(value.end_with?(test_against), negation)
    end

    # Case-insensitive regex test (+comparisons.ts:143-152+ — +new RegExp(t, 'i')+).
    # +value+ is lowercased; the pattern keeps its case but matches
    # case-insensitively via the +i+ flag.
    #
    # @return [Boolean]
    def self.regex_matches(value, test_against, negation = false)
      value = value.to_s.downcase
      pattern = Regexp.new(test_against.to_s, Regexp::IGNORECASE)
      negation_check(!pattern.match(value).nil?, negation)
    end

    # Presence test (+comparisons.ts:154-161+): true unless the value is
    # +UNDEFINED+ (JS +undefined+), +nil+ (JS +null+), or the empty string.
    #
    # @return [Boolean]
    def self.exists(value, _test_against = nil, negation = false)
      value_exists = !value.equal?(UNDEFINED) && !value.nil? && value != ""
      negation_check(value_exists, negation)
    end

    # Absence test — the logical inverse of {exists} (+comparisons.ts:163-170+).
    #
    # @return [Boolean]
    def self.not_exists(value, _test_against = nil, negation = false)
      value_not_exists = value.equal?(UNDEFINED) || value.nil? || value == ""
      negation_check(value_not_exists, negation)
    end

    # Alias of {not_exists} (+comparisons.ts:172+ — +doesNotExist = this.not_exists+).
    def self.does_not_exist(value, test_against = nil, negation = false)
      not_exists(value, test_against, negation)
    end

    # Maps each wire comparison operator name to its implementing method symbol.
    DISPATCH = {
      "equals" => :equals,
      "equalsNumber" => :equals_number,
      "matches" => :matches,
      "less" => :less,
      "lessEqual" => :less_equal,
      "contains" => :contains,
      "isIn" => :is_in,
      "startsWith" => :starts_with,
      "endsWith" => :ends_with,
      "regexMatches" => :regex_matches,
      "exists" => :exists,
      "not_exists" => :not_exists,
      "doesNotExist" => :does_not_exist
    }.freeze

    # The wire-name -> Ruby-method dispatch map (the two-worlds rule for
    # operators). Keys are byte-identical to the rule JSON +match_type+ strings;
    # {RuleManager} looks an operator up here and invokes the mapped method.
    #
    # @return [Hash{String=>Symbol}] frozen 13-entry map.
    def self.dispatch
      DISPATCH
    end

    # JS +isNumeric+ (+string-utils.ts:68-74+): numbers are numeric when finite;
    # strings are numeric only when they match {NUMERIC_REGEXP} and parse finite.
    # @api private
    def self.numeric?(value)
      return value.finite? if value.is_a?(Numeric)
      return false unless value.is_a?(String) && NUMERIC_REGEXP.match?(value)

      Float(value.delete(",")).finite?
    rescue ArgumentError, TypeError
      false
    end

    # JS +toNumber+ (+string-utils.ts:81-91+): numbers pass through; strings with
    # a leading +"0"+ thousands segment treat commas as decimal points, otherwise
    # commas are stripped, then parsed as a float.
    # @api private
    def self.to_number(value)
      return value if value.is_a?(Numeric)

      str = value.to_s
      parts = str.split(",")
      normalized = parts[0] == "0" ? str.tr(",", ".") : str.delete(",")
      Float(normalized)
    end

    # Numeric comparison core shared by {less}/{lessEqual}. Both sides are
    # numerically normalized when numeric-looking; if the resulting types differ
    # (one number, one non-number) the comparison is +false+ — JS ts:52-54/65-67.
    # @api private
    def self.compare_numeric(value, test_against, negation)
      value = to_number(value) if numeric?(value)
      test_against = to_number(test_against) if numeric?(test_against)
      return negation_check(false, negation) unless same_compare_type?(value, test_against)

      negation_check(yield(value, test_against), negation)
    end

    # JS +typeof+ parity for the {compare_numeric} guard: a normalized numeric is
    # type "number"; everything else compares by whether BOTH are Numeric or
    # NEITHER is (a String stays "string").
    # @api private
    def self.same_compare_type?(value, test_against)
      value.is_a?(Numeric) == test_against.is_a?(Numeric)
    end

    # JS +_returnNegationCheck+ (+comparisons.ts:174-183+): invert when negated.
    # @api private
    def self.negation_check(result, negation)
      negation ? !result : result
    end

    private_class_method :compare_numeric, :same_compare_type?, :negation_check
  end
end
