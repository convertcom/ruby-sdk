# frozen_string_literal: true

module ConvertSdk
  # The audience/segmentation rule walk — OR -> AND -> OR_WHEN — ported EXACTLY
  # from the JS SDK +packages/rules/src/rule-manager.ts+. JS is the only truth
  # here; the PHP port is quarantined (it diverges on the existence operators and
  # on +isIn+ case-folding — see {Comparisons}).
  #
  # Structure & short-circuit order (mirrors rule-manager.ts:117-255):
  #   * Top OR (+isRuleMatched+): for each AND-group, +match = process_and+;
  #     return +true+ on the first matching group; after the loop return +match+
  #     unless it is +false+ (so a {RuleError} sentinel propagates out). A missing
  #     or empty +OR+ logs +RULE_NOT_VALID+ at warn and returns +false+.
  #   * AND (+process_and+): for each OR_WHEN leaf-list, +match = process_or_when+;
  #     return +match+ on the FIRST non-+true+ result (a +false+ or a sentinel
  #     short-circuits the AND). All +true+ -> +true+. Missing/empty +AND+ ->
  #     +RULE_NOT_VALID+ warn + +false+.
  #   * OR_WHEN (+process_or_when+): for each leaf rule, +match = process_rule_item+;
  #     return +true+ on the first match; after the loop return +match+ unless it
  #     is +false+. Missing/empty +OR_WHEN+ -> +RULE_NOT_VALID+ warn + +false+.
  #
  # FR22 safety invariant: EVERY empty/missing block shape returns +false+ with a
  # +RULE_NOT_VALID+ warn — an empty audience excludes everyone, it never matches
  # everyone.
  #
  # The undefined-fallback (rule-manager.ts:323-333): when the data key for a leaf
  # is ABSENT and the operator is +exists+/+doesNotExist+, the operator is invoked
  # against {Comparisons::UNDEFINED} (JS +undefined+) so existence semantics hold
  # for absent keys. Ruby models key-absence with the {Comparisons::UNDEFINED}
  # marker because a plain +nil+ means "present null value" (JS +null+), which is
  # a different existence outcome.
  #
  # RuleError propagation: a leaf that returns a {RuleError} sentinel propagates
  # it up the walk via the non-true / non-false short-circuits above (Story 2.11
  # maps the surfaced sentinel to the public return).
  #
  # Pure in-memory (NFR1). Rule options (+keys_case_sensitive+, +negation+) come
  # from the injected {Config}, never inline. Valid-rule outcomes log at debug;
  # invalid/empty shapes log +RULE_NOT_VALID+ at warn (rule-manager.ts levels).
  #
  # @api private
  class RuleManager
    # The +RULE_NOT_VALID+ message — byte-identical to the JS SDK dictionary
    # (+packages/enums/src/dictionary.ts:12+: "Provided rule is not valid"). Logged
    # at warn for every empty/missing/invalid block, the FR22 exclusion signal.
    RULE_NOT_VALID = "Provided rule is not valid"

    # Build a rule walker bound to a {Config}'s rule options and a comparison
    # processor.
    #
    # @param config [Config] supplies +keys_case_sensitive+ and +negation+.
    # @param comparisons [#dispatch] the operator processor (defaults to
    #   {Comparisons}); must expose +dispatch+ (wire-name => method symbol) and
    #   respond to each mapped method as +(value, test_against, negation)+.
    # @param log_manager [LogManager, nil] optional logger; warn for invalid
    #   shapes, debug for valid-rule outcomes.
    def initialize(config:, comparisons: Comparisons, log_manager: nil)
      @keys_case_sensitive = config.keys_case_sensitive
      @comparisons = comparisons
      @log_manager = log_manager
    end

    # Walk a rule set against a data hash. The top OR level.
    #
    # @param data [Hash{String=>Object}] the key-value data to match.
    # @param rule_set [Hash] the OR/AND/OR_WHEN rule structure.
    # @param log_entry [String, nil] an optional label for the entity being matched.
    # @return [Boolean, Sentinel] true/false, or a {RuleError} sentinel propagated
    #   from a leaf.
    def is_rule_matched(data, rule_set, log_entry = nil)
      or_groups = rule_set.is_a?(Hash) ? rule_set["OR"] : nil
      unless or_groups.is_a?(Array) && !or_groups.empty?
        warn_rule_not_valid("RuleManager#is_rule_matched", log_entry)
        return false
      end

      match = false
      or_groups.each do |and_group|
        match = process_and(data, and_group)
        return true if match == true

        log_outcome("RuleManager#is_rule_matched", match, log_entry)
      end
      return match if match != false

      false
    end

    private

    # AND block: every OR_WHEN leaf-list must return true. Returns the first
    # non-true result (false or a sentinel short-circuits). rule-manager.ts:191-220.
    def process_and(data, and_group)
      leaves = and_group.is_a?(Hash) ? and_group["AND"] : nil
      unless leaves.is_a?(Array) && !leaves.empty?
        warn_rule_not_valid("RuleManager#process_and")
        return false
      end

      leaves.each do |or_when|
        match = process_or_when(data, or_when)
        return match if match != true
      end
      @log_manager&.debug("RuleManager#process_and: AND block matched")
      true
    end

    # OR_WHEN block: the first matching leaf wins. After the loop, returns the
    # last result unless false (so a sentinel propagates). rule-manager.ts:229-255.
    def process_or_when(data, or_when)
      leaves = or_when.is_a?(Hash) ? or_when["OR_WHEN"] : nil
      unless leaves.is_a?(Array) && !leaves.empty?
        warn_rule_not_valid("RuleManager#process_or_when")
        return false
      end

      match = false
      leaves.each do |rule|
        match = process_rule_item(data, rule)
        return true if match == true
      end
      return match if match != false

      false
    end

    # A single leaf rule. Validates shape, resolves the operator from the
    # comparison processor's dispatch map, and evaluates it against the matching
    # data value — or against {Comparisons::UNDEFINED} for an absent key under an
    # existence operator. rule-manager.ts:264-365.
    def process_rule_item(data, rule)
      unless valid_rule?(rule)
        warn_rule_not_valid("RuleManager#process_rule_item")
        return false
      end

      negation = rule["matching"]["negated"] || false
      match_type = rule["matching"]["match_type"]
      method = @comparisons.dispatch[match_type]
      unless method
        @log_manager&.warn(
          "RuleManager#process_rule_item: rule matching type #{match_type.inspect} is not supported"
        )
        return false
      end

      evaluate_leaf(data, rule, match_type, method, negation)
    end

    # Resolve the data value for the leaf's key and invoke the operator. Iterates
    # the data keys honoring +keys_case_sensitive+; on a key match invokes the
    # operator with the data value. On no key match, an existence operator is
    # invoked against the UNDEFINED marker (undefined-fallback). Otherwise false.
    def evaluate_leaf(data, rule, match_type, method, negation)
      data_value = lookup_data_value(data, rule["key"])
      unless data_value.equal?(Comparisons::UNDEFINED)
        result = @comparisons.public_send(method, data_value, rule["value"], negation)
        debug_outcome("key matched", match_type, result)
        return result
      end

      # Key absent: only the existence operators fall back to the UNDEFINED
      # marker (rule-manager.ts:323-333); everything else is a no-match.
      if existence_operator?(match_type)
        result = @comparisons.public_send(method, Comparisons::UNDEFINED, rule["value"], negation)
        debug_outcome("existence-fallback", match_type, result)
        return result
      end

      @log_manager&.debug("RuleManager#evaluate_leaf: key #{rule["key"].inspect} not found in data")
      false
    end

    # Resolve the data value for a rule key honoring +keys_case_sensitive+.
    # Returns {Comparisons::UNDEFINED} when the key is ABSENT — distinct from a
    # present +nil+ value (JS null), which is returned as +nil+.
    def lookup_data_value(data, rule_key)
      return Comparisons::UNDEFINED unless data.is_a?(Hash) && !data.empty?

      target = @keys_case_sensitive ? rule_key : rule_key.to_s.downcase
      data.each do |key, value|
        k = @keys_case_sensitive ? key : key.to_s.downcase
        return value if k == target
      end
      Comparisons::UNDEFINED
    end

    # Debug-log a leaf evaluation outcome.
    def debug_outcome(path, match_type, result)
      @log_manager&.debug(
        "RuleManager#evaluate_leaf: #{path} match_type=#{match_type.inspect} result=#{result.inspect}"
      )
    end

    # JS +isValidRule+ (rule-manager.ts:162-182): requires a +matching+ object
    # with string +match_type+ and boolean +negated+; existence operators are
    # valid without a +value+, all others require a +value+ field.
    def valid_rule?(rule)
      return false unless rule.is_a?(Hash)

      matching = rule["matching"]
      return false unless matching.is_a?(Hash)
      return false unless matching["match_type"].is_a?(String)
      return false unless [true, false].include?(matching["negated"])
      return true if existence_operator?(matching["match_type"])

      rule.key?("value")
    end

    # The existence operators get the undefined-fallback and are value-optional.
    # Mirrors the JS CookieMatchingOptions.EXISTS / DOES_NOT_EXIST special-case.
    def existence_operator?(match_type)
      %w[exists doesNotExist].include?(match_type)
    end

    # Emit a RULE_NOT_VALID warn (FR22 exclusion signal) — rule-manager.ts warn
    # sites at :148/:214/:249/:359.
    def warn_rule_not_valid(site, log_entry = nil)
      suffix = log_entry ? " (#{log_entry})" : ""
      @log_manager&.warn("#{site}: #{RULE_NOT_VALID}#{suffix}")
    end

    # Debug-log a valid-rule outcome (match / no-match / sentinel) at the OR level.
    def log_outcome(site, match, log_entry)
      suffix = log_entry ? " (#{log_entry})" : ""
      @log_manager&.debug("#{site}: outcome=#{match.inspect}#{suffix}")
    end
  end
end
