# frozen_string_literal: true

module ConvertSdk
  # Variation-selection support — the thin per-experience / across-experiences
  # entry surface over the {DataManager} decision flow.
  #
  # This mirrors the JS +experience-manager.ts+ division of labor EXACTLY: the
  # ExperienceManager owns variation SELECTION (the public-ish +select_variation+
  # / +select_variations+ seams that {Context} drives), while the ORDERED decision
  # FLOW — entity -> archived -> environment -> stored-bucketing -> locations ->
  # audiences -> custom segments -> traffic allocation -> variation — lives in
  # {DataManager#get_bucketing} (JS +data-manager.ts:227-720+). A reordered step
  # is a parity bug; the order is owned in ONE place (DataManager) and exercised,
  # not duplicated here.
  #
  # == +select_variation+ (one experience by key)
  #
  # Delegates straight to {DataManager#get_bucketing}, returning a frozen
  # {BucketedVariation} on a hit or a {Sentinel} ({RuleError}/{BucketingError}) on
  # a miss — JS +selectVariation+ (+experience-manager.ts:110-116+).
  #
  # == +select_variations+ (all experiences)
  #
  # Maps {DataManager#get_bucketing} over EVERY configured experience and FILTERS
  # OUT every non-decision: +nil+, {RuleError}, and {BucketingError} sentinels.
  # This is the JS +selectVariations+ contract (+experience-manager.ts:159-168+):
  # the across-all-experiences call returns ONLY the variations a visitor was
  # actually bucketed into; misses never appear in the list (FR16 return shape).
  #
  # @api private
  class ExperienceManager
    # @param data_manager [DataManager] the decision-flow owner (holds the config
    #   snapshot, the bucketing/rule collaborators, and the visitor store seam).
    # @param log_manager [LogManager, nil] optional debug logger.
    def initialize(data_manager:, log_manager: nil)
      @data_manager = data_manager
      @log_manager = log_manager
    end

    # Decide one experience for a visitor by experience key.
    #
    # @param visitor_id [String] the visitor identifier.
    # @param experience_key [String] the experience +key+ to decide.
    # @param attributes [Hash] bucketing attributes — +:visitor_properties+
    #   (audiences), +:location_properties+ (locations/site_area), +:environment+,
    #   +:update_visitor_properties+.
    # @return [BucketedVariation, Sentinel] a frozen variation, or a
    #   {RuleError}/{BucketingError} sentinel on a miss.
    def select_variation(visitor_id, experience_key, attributes = {})
      @data_manager.get_bucketing(visitor_id, experience_key, attributes)
    end

    # Decide ALL configured experiences for a visitor, returning only the
    # successful bucketed variations (misses filtered — JS parity).
    #
    # @param visitor_id [String] the visitor identifier.
    # @param attributes [Hash] bucketing attributes (see {#select_variation}).
    # @return [Array<BucketedVariation>] the frozen variations the visitor was
    #   bucketed into (sentinels and nils excluded).
    def select_variations(visitor_id, attributes = {})
      @data_manager.experiences.filter_map do |experience|
        next unless experience.is_a?(Hash)

        result = @data_manager.get_bucketing(visitor_id, experience["key"], attributes)
        result if result.is_a?(BucketedVariation)
      end
    end
  end
end
