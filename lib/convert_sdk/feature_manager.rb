# frozen_string_literal: true

require "json"

module ConvertSdk
  # Feature resolution + typed-variable casting — the MAPPING + CASTING layer
  # that turns the Epic 2 bucketing decisions (Story 2.11) into typed feature
  # flags (FR24–FR27).
  #
  # == Features resolve THROUGH experiences (FR26)
  #
  # There is NO independent feature decision path. A feature is ENABLED exactly
  # when the visitor is bucketed — via the ordered decision flow owned by
  # {DataManager#get_bucketing} — into a variation that carries that feature. The
  # carrying link lives in the variation's +changes+: a change with
  # +type == "fullStackFeature"+ whose +data.feature_id+ matches a declared
  # feature, and whose +data.variables_data+ holds the raw (string) variable
  # values. This manager maps those bucketed variations onto declared features
  # and casts the variable values; it NEVER re-evaluates rules (that would be a
  # parity bug — the decision flow is owned in ONE place, the DataManager).
  #
  # == Typed variables (FR27) — the developer-experience core
  #
  # Each declared feature lists its variables as +{key, type}+; the bucketed
  # variation supplies the raw values. {#cast_type} mirrors the JS
  # +castType+ contract (javascript-sdk +packages/utils/src/types-utils.ts:13-54+)
  # EXACTLY — five literal type strings:
  #
  #   string  -> String(value)
  #   boolean -> "true" -> true, "false" -> false, else truthiness
  #   integer -> true->1, false->0, else parseInt-style (leading digits)
  #   float   -> true->1.0, false->0.0, else parseFloat-style (leading number)
  #   json    -> already a Hash/Array? as-is; else JSON.parse, on FAILURE -> raw String
  #
  # There is NO +number+ type in the JS switch — none is added here. An unknown
  # type returns the value unchanged (the JS +default+ branch). Casting is
  # data-driven from the config's declared variable types — no per-feature cases.
  #
  # == Miss semantics (AC#5; feature-manager.ts:206-218)
  #
  # A miss is NEVER an exception. {#run_feature} returns a frozen
  # {BucketedFeature} with +status == FeatureStatus::DISABLED+:
  #   * feature DECLARED but visitor not bucketed into a carrying variation ->
  #     +{id, name, key, status: DISABLED}+
  #   * feature NOT declared at all -> +{key, status: DISABLED}+
  # Each miss is PAIRED with a +debug+ reason log (a Ruby observability addition;
  # JS returns the disabled feature silently).
  #
  # == Sticky transitivity
  #
  # A returning visitor's stored bucketing (2.11) drives feature stability
  # automatically — there is NO feature-level storage here.
  #
  # @api private
  class FeatureManager
    # Variation-change type that carries a fullstack feature link. Wire value
    # byte-identical to the JS enum (variation-change-type.ts:13). Held here
    # (not inlined at the use site) so the wire string lives in ONE place.
    FULLSTACK_FEATURE = "fullStackFeature"

    # The values JS treats as falsey for the +!!value+ boolean cast (after the
    # explicit "true"/"false" string checks): nil, false, "", and 0.
    JS_FALSEY = [nil, false, "", 0].freeze

    # @param data_manager [DataManager] the 2.11 decision-flow owner (config
    #   readers + +get_bucketing+).
    # @param log_manager [LogManager, nil] optional debug/warn logger.
    def initialize(data_manager:, log_manager: nil)
      @data_manager = data_manager
      @log_manager = log_manager
    end

    # Resolve a SINGLE feature for a visitor (FR24).
    #
    # Mirrors JS +runFeature+ (feature-manager.ts:180-219): the feature is looked
    # up by key; if declared, the bucketing flow runs FILTERED to this feature.
    # On one carrying variation a single ENABLED {BucketedFeature} is returned; on
    # several (the feature appears in multiple bucketed variations) an Array of
    # ENABLED {BucketedFeature}s; on none the DISABLED fallback (+{id,name,key}+).
    # An undeclared feature returns the +{key}+-only DISABLED fallback. Each miss
    # is paired with a debug log; never raises.
    #
    # @param visitor_id [String] the visitor identifier.
    # @param feature_key [String] the feature +key+ to resolve.
    # @param attributes [Hash] bucketing attributes (+:visitor_properties+,
    #   +:location_properties+, +:environment+) — see {DataManager#get_bucketing}.
    # @return [BucketedFeature, Array<BucketedFeature>] enabled feature(s) or a
    #   frozen DISABLED {BucketedFeature} on a miss.
    def run_feature(visitor_id, feature_key, attributes = {})
      declared = @data_manager.feature_by_key(feature_key)
      unless declared
        @log_manager&.debug("FeatureManager#run_feature: feature not declared key=#{feature_key}")
        return disabled_feature(key: feature_key)
      end

      enabled = run_features(visitor_id, attributes, features: [feature_key])
      if enabled.empty?
        @log_manager&.debug("FeatureManager#run_feature: not bucketed into a carrying variation key=#{feature_key}")
        return disabled_from_declared(declared)
      end

      enabled.length == 1 ? enabled.first : enabled
    end

    # Resolve ALL applicable features for a visitor (FR25).
    #
    # Mirrors JS +runFeatures+ (feature-manager.ts:327-463) under the Ruby
    # across-all-experiences parity decision (Story 2.11 {ExperienceManager#select_variations}):
    # misses are FILTERED OUT of the bucketed-variation set (sentinels never
    # propagate), then every declared feature carried by a bucketed variation is
    # collected as an ENABLED {BucketedFeature} (variables cast per declared type).
    # When NO +features+ filter is supplied, every declared feature NOT already
    # enabled is appended as a DISABLED {BucketedFeature} — so callers always see
    # the full feature roster. With a +features+ filter, only enabled matches are
    # returned (no DISABLED padding). Never raises.
    #
    # @param visitor_id [String] the visitor identifier.
    # @param attributes [Hash] bucketing attributes (see {#run_feature}).
    # @param experiences [Array<String>, nil] optional experience-key filter.
    # @param features [Array<String>, nil] optional feature-key filter (suppresses
    #   the DISABLED padding).
    # @return [Array<BucketedFeature>] the resolved features.
    def run_features(visitor_id, attributes = {}, experiences: nil, features: nil)
      declared_by_id = features_by_id
      variations = bucketed_variations(visitor_id, attributes, experiences)

      bucketed = collect_enabled(variations, declared_by_id, features)

      # Pad with DISABLED features ONLY when no feature filter is supplied.
      append_disabled(bucketed, declared_by_id) if features.nil?
      bucketed
    end

    # Cast a raw variable value to its declared type. Mirrors JS +castType+
    # (types-utils.ts:13-54) exactly — see the class doc for the truth table.
    # Never raises: non-numeric integer/float inputs degrade to a leading-number
    # parse (0 / 0.0 when there is no leading number), and a +json+ parse failure
    # falls back to the raw String (JS +catch -> String(value)+).
    #
    # @param value [Object] the raw (typically String) variable value.
    # @param type [String] the declared type: string/boolean/integer/float/json.
    # @return [Object] the cast value.
    def cast_type(value, type)
      case type
      when "string"  then value.to_s
      when "boolean" then cast_boolean(value)
      when "integer" then cast_integer(value)
      when "float"   then cast_float(value)
      when "json"    then cast_json(value)
      else value # JS default branch — unknown type passes through unchanged.
      end
    end

    private

    # Bucket the (optionally experience-filtered) experiences through the 2.11
    # decision flow, keeping ONLY successful {BucketedVariation}s (sentinels and
    # nils filtered — the Ruby across-all parity decision, Story 2.11).
    def bucketed_variations(visitor_id, attributes, experience_keys)
      experiences = target_experiences(experience_keys)
      experiences.filter_map do |experience|
        next unless experience.is_a?(Hash)

        result = @data_manager.get_bucketing(visitor_id, experience["key"], attributes)
        result if result.is_a?(BucketedVariation)
      end
    end

    # The experiences to decide: the whole configured list, or just those whose
    # key is in +experience_keys+ when a filter is supplied.
    def target_experiences(experience_keys)
      all = @data_manager.experiences
      return all if experience_keys.nil? || experience_keys.empty?

      wanted = experience_keys.map(&:to_s)
      all.select { |experience| experience.is_a?(Hash) && wanted.include?(experience["key"].to_s) }
    end

    # Walk every bucketed variation's +fullStackFeature+ changes, mapping each to
    # its declared feature (by id), casting the variables, and building an ENABLED
    # {BucketedFeature}. Honours the optional +feature_keys+ filter.
    def collect_enabled(variations, declared_by_id, feature_keys)
      bucketed = [] #: Array[BucketedFeature]
      variations.each do |variation|
        feature_changes(variation).each do |change|
          feature = enabled_feature_from_change(variation, change, declared_by_id, feature_keys)
          bucketed << feature if feature
        end
      end
      bucketed
    end

    # The +fullStackFeature+ changes carried by a bucketed variation (a warn is
    # logged for any non-feature change, mirroring JS VARIATION_CHANGE_NOT_SUPPORTED).
    def feature_changes(variation)
      changes = variation.changes
      return [] unless changes.is_a?(Array)

      changes.select do |change|
        if change.is_a?(Hash) && change["type"] == FULLSTACK_FEATURE
          true
        else
          @log_manager&.warn("FeatureManager#run_features: unsupported variation change type")
          false
        end
      end
    end

    # Build the ENABLED {BucketedFeature} for one feature change, or nil when the
    # change has no feature_id, the feature is undeclared, or it is filtered out.
    def enabled_feature_from_change(variation, change, declared_by_id, feature_keys)
      data = change["data"]
      declared = declared_for_change(data, declared_by_id)
      return nil if declared.nil?
      return nil if filtered_out?(declared, feature_keys)

      build_enabled(variation, declared, cast_variables(declared, data["variables_data"]))
    end

    # The declared feature a feature-change maps to (by data.feature_id), or nil
    # when the change carries no feature_id or the id is undeclared (each logged).
    def declared_for_change(data, declared_by_id)
      feature_id = data.is_a?(Hash) ? data["feature_id"] : nil
      unless feature_id
        @log_manager&.warn("FeatureManager#run_features: feature change without feature_id")
        return nil
      end
      declared_by_id[feature_id.to_s]
    end

    # True when a feature filter is supplied and this declared feature's key is
    # not in it.
    def filtered_out?(declared, feature_keys)
      return false if feature_keys.nil?

      !feature_keys.map(&:to_s).include?(declared["key"].to_s)
    end

    # Cast every supplied raw variable per its declared type (data-driven). A
    # variable with no declared type passes through uncast (JS warns
    # FEATURE_VARIABLES_TYPE_NOT_FOUND). Returns a fresh string-keyed Hash.
    def cast_variables(declared, raw)
      unless raw.is_a?(Hash)
        @log_manager&.warn("FeatureManager#run_features: feature variables not found")
        return {}
      end

      definitions = declared["variables"]
      cast = {} #: Hash[String, untyped]
      raw.each do |name, value|
        type = variable_type(definitions, name)
        if type
          cast[name.to_s] = cast_type(value, type)
        else
          @log_manager&.warn("FeatureManager#run_features: variable type not found name=#{name}")
          cast[name.to_s] = value
        end
      end
      cast
    end

    # The declared type for a variable name within a feature's +variables+ list.
    def variable_type(definitions, name)
      return nil unless definitions.is_a?(Array)

      definition = definitions.find { |d| d.is_a?(Hash) && d["key"] == name }
      definition && definition["type"]
    end

    # A frozen ENABLED {BucketedFeature} with the experience provenance + the
    # declared feature's id/name/key + the cast variables.
    def build_enabled(variation, declared, variables)
      BucketedFeature.new(
        experience_id: variation.experience_id,
        experience_key: variation.experience_key,
        experience_name: variation.experience_name,
        id: declared["id"],
        key: declared["key"],
        name: declared["name"],
        status: FeatureStatus::ENABLED,
        variables: variables
      )
    end

    # Append a DISABLED {BucketedFeature} for every declared feature not already
    # present (enabled) in +bucketed+ — JS feature-manager.ts:448-461.
    def append_disabled(bucketed, declared_by_id)
      enabled_ids = bucketed.map(&:id)
      declared_by_id.each_value do |declared|
        next if enabled_ids.include?(declared["id"])

        bucketed << disabled_from_declared(declared)
      end
    end

    # A frozen DISABLED {BucketedFeature} for a DECLARED feature (id/name/key) —
    # the "visitor not bucketed" miss shape (feature-manager.ts:206-211).
    def disabled_from_declared(declared)
      BucketedFeature.new(
        id: declared["id"], name: declared["name"], key: declared["key"],
        status: FeatureStatus::DISABLED
      )
    end

    # A frozen DISABLED {BucketedFeature} for an UNDECLARED feature (key only) —
    # the "feature not declared at all" miss shape (feature-manager.ts:214-217).
    def disabled_feature(key:)
      BucketedFeature.new(key: key, status: FeatureStatus::DISABLED)
    end

    # Declared features keyed by id (String), for the change->feature mapping and
    # the DISABLED padding. Mirrors JS getListAsObject('id').
    def features_by_id
      result = {} #: Hash[String, untyped]
      @data_manager.features.each do |feature|
        result[feature["id"].to_s] = feature if feature.is_a?(Hash) && feature["id"]
      end
      result
    end

    # boolean: "true"->true, "false"->false, else Ruby truthiness of the value
    # (JS !!value; "" and 0 are falsey in JS, so they map to false).
    def cast_boolean(value)
      return true if value == "true"
      return false if value == "false"

      !JS_FALSEY.include?(value)
    end

    # integer: true->1, false->0, else parseInt-style — leading integer digits of
    # the string, 0 when there is no leading integer (JS parseInt returns NaN, but
    # the never-crash contract degrades to 0).
    def cast_integer(value)
      return 1 if value == true
      return 0 if value == false
      return value if value.is_a?(Integer)

      str = value.to_s.strip
      match = str.match(/\A[+-]?\d+/)
      match ? match[0].to_i : 0
    end

    # float: true->1.0, false->0.0, else parseFloat-style — leading numeric prefix
    # of the string, 0.0 when there is no leading number (degrade, never crash).
    def cast_float(value)
      return 1.0 if value == true
      return 0.0 if value == false
      return value + 0.0 if value.is_a?(Integer) || value.is_a?(Float)

      str = value.to_s.strip
      match = str.match(/\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/)
      match ? match[0].to_f : 0.0
    end

    # json: an already-parsed Hash/Array passes through; otherwise JSON.parse,
    # and on a parse failure fall back to the raw String (JS catch -> String(value)).
    def cast_json(value)
      return value if value.is_a?(Hash) || value.is_a?(Array)

      begin
        JSON.parse(value.to_s)
      rescue JSON::ParserError, TypeError
        value.to_s
      end
    end
  end
end
