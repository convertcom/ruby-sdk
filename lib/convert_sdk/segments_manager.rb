# frozen_string_literal: true

module ConvertSdk
  # Visitor segmentation — the REPORTING-data layer that attaches segment ids to a
  # visitor's +StoreData+ in the JS SDK's wire shape (FR28–FR30). Ported from the
  # JS SDK +packages/segments/src/segments-manager.ts+; the PHP reference is
  # QUARANTINED here because it diverges on two wire keys.
  #
  # == PHP-divergence #2 — the wire-key quarantine (FR30)
  #
  # JS +SegmentsKeys+ (+segments-keys.ts:7-15+) emit camelCase:
  # +visitorType+ / +customSegments+. PHP +SegmentsKeys.php:14-15+ emit snake_case:
  # +visitor_type+ / +custom_segments+ — a real, disk-verified divergence. Segment
  # data rides the tracking payload's +segments+ object (Epic 4 +ApiManager+ emits
  # the visitor's stored +segments+ verbatim), so the wrong key would silently
  # mis-filter every Ruby segment-report. Ruby follows JS: the seven report-segment
  # keys, and +customSegments+ in particular, are the ONLY ones persisted, as
  # camelCase STRINGS at rest in +StoreData+. The {SegmentsManager} never produces
  # the PHP variants; Story 3.2's quarantine spec asserts their absence.
  #
  # == The report-segment filter ({#filter_report_segments}, +data-manager.ts:1180-1199+)
  #
  # Exactly seven keys are report-segments: +country+, +browser+, +devices+,
  # +source+, +campaign+, +visitorType+, +customSegments+. {#put_segments} keeps
  # ONLY these; every other key is silently DROPPED (JS routes them to a separate
  # +properties+ bucket the segments layer ignores) — IGNORE, not reject. Ruby adds
  # a +debug+ line naming the dropped keys (an observability addition; JS drops
  # silently). A filter that leaves NOTHING is a no-op write (JS +if (reportSegments)+).
  #
  # == Custom-segment evaluation REUSES the rule engine ({#select_custom_segments})
  #
  # +run_custom_segments+ does NOT introduce new rule logic. For each requested
  # segment key it looks up the {ConfigSegment} entity (DataManager +segments+
  # reader), evaluates that segment's +rules+ against the supplied
  # +segment_rule+ data via {RuleManager#is_rule_matched} (so NEED_MORE_DATA and
  # every operator semantic come for FREE), and — on a match — appends the
  # segment's id to the visitor's stored +customSegments+ list (deduped). A
  # surfaced {RuleError} sentinel propagates out verbatim (mirrors JS
  # +setCustomSegments+'s +Object.values(RuleError).includes(...)+ early-return).
  #
  # == Persistence
  #
  # All writes flow through the {DataStoreManager} atomic visitor-data merge
  # (Story 2.1) into +StoreData["segments"]+. Stored data is string-keyed
  # wire-world by design (so Epic 4's payload builder needs zero translation).
  #
  # @api private
  class SegmentsManager
    # The +customSegments+ wire key — byte-identical to JS
    # +SegmentsKeys.CUSTOM_SEGMENTS+ (+segments-keys.ts:14+). The visitor's matched
    # custom-segment ids live under this key in +StoreData["segments"]+.
    CUSTOM_SEGMENTS = "customSegments"

    # The full report-segment key set — byte-identical to JS +SegmentsKeys+
    # (+segments-keys.ts:7-15+). The report-segment filter is restricted to exactly
    # these seven; +visitorType+/+customSegments+ are the JS wire keys that diverge
    # from PHP's snake_case variants (FR30). The SINGLE source of the allowed set.
    SEGMENTS_KEYS = %w[
      country browser devices source campaign visitorType customSegments
    ].freeze

    # @param data_manager [DataManager] the config reader surface (supplies the
    #   {ConfigSegment} entities by key and the account/project store-key halves).
    # @param data_store_manager [DataStoreManager] the persistence port (atomic
    #   visitor-data merge into +StoreData["segments"]+).
    # @param account_resolver [#call] resolves the account id (store-key half).
    # @param project_resolver [#call] resolves the project id (store-key half).
    # @param rule_manager [RuleManager] the Epic 2 rule walker reused for
    #   custom-segment evaluation (never re-implemented here).
    # @param log_manager [LogManager, nil] optional logger; debug on misses/drops,
    #   warn on already-present ids.
    def initialize(data_manager:, data_store_manager:, account_resolver:,
                   project_resolver:, rule_manager:, log_manager: nil)
      @data_manager = data_manager
      @data_store_manager = data_store_manager
      @account_resolver = account_resolver
      @project_resolver = project_resolver
      @rule_manager = rule_manager
      @log_manager = log_manager
    end

    # Set default report-segments for a visitor (JS +setDefaultSegments+ ->
    # +putSegments+, +context.ts:434-436+ / +segments-manager.ts:78-85+).
    #
    # The supplied segments are passed through {#filter_report_segments} (only the
    # seven {SEGMENTS_KEYS} survive); a non-empty result is merged into the
    # visitor's +StoreData["segments"]+ via the atomic store merge. An all-dropped
    # input is a no-op (JS +if (reportSegments)+).
    #
    # @param visitor_id [String]
    # @param segments [Hash] the candidate report-segments (string-keyed wire shape).
    # @return [void]
    def put_segments(visitor_id, segments)
      report_segments = filter_report_segments(segments)
      return if report_segments.empty?

      merge_segments(visitor_id, report_segments)
      nil
    end

    # Evaluate the named custom segments for a visitor and attach matching ids
    # (JS +selectCustomSegments+ -> +setCustomSegments+, +segments-manager.ts:153-185+).
    #
    # Each requested key is resolved to a {ConfigSegment} via the DataManager
    # +segments+ reader; the segment's +rules+ are walked against +segment_rule+
    # by {RuleManager#is_rule_matched}. A surfaced {RuleError} sentinel propagates
    # out verbatim (no attachment). Matching segment ids are appended to the
    # visitor's stored +customSegments+ list (deduped); an unknown key is skipped
    # with a debug log.
    #
    # @param visitor_id [String]
    # @param segment_keys [Array<String>] the segment keys to evaluate.
    # @param segment_rule [Hash, nil] the visitor data the segment rules match
    #   against; +nil+ attaches every resolved segment unconditionally (JS:
    #   +if (!segmentRule || segmentsMatched)+).
    # @return [Hash, Sentinel, nil] the updated segments hash, a propagated
    #   {RuleError}, or +nil+ when nothing matched.
    def select_custom_segments(visitor_id, segment_keys, segment_rule = nil)
      segments = lookup_segments(segment_keys)
      set_custom_segments(visitor_id, segments, segment_rule)
    end

    private

    # Keep ONLY the seven {SEGMENTS_KEYS} report-segments; silently drop the rest
    # (JS +filterReportSegments+, +data-manager.ts:1180-1199+ — non-segment keys go
    # to a +properties+ bucket the segments layer ignores). Dropped keys are named
    # in a debug line (Ruby observability addition). Returns a string-keyed hash
    # (possibly empty).
    def filter_report_segments(segments)
      return {} unless segments.is_a?(Hash)

      kept = {} #: Hash[String, untyped]
      dropped = [] #: Array[String]
      segments.each do |key, value|
        if SEGMENTS_KEYS.include?(key)
          kept[key] = value
        else
          dropped << key
        end
      end
      unless dropped.empty?
        @log_manager&.debug("SegmentsManager#filter_report_segments: dropped non-report keys #{dropped.inspect}")
      end
      kept
    end

    # Resolve the requested segment keys to {ConfigSegment} entities via the
    # DataManager +segments+ reader (JS +getEntities(keys, 'segments')+). Unknown
    # keys yield no entity and are debug-logged + skipped. Preserves request order.
    def lookup_segments(segment_keys)
      return [] unless segment_keys.is_a?(Array)

      all = @data_manager.segments
      segment_keys.filter_map do |key|
        entity = all.find { |seg| seg.is_a?(Hash) && seg["key"] == key }
        @log_manager&.debug("SegmentsManager#lookup_segments: no segment found for key=#{key}") unless entity
        entity
      end
    end

    # The id-attachment core (JS +setCustomSegments+, +segments-manager.ts:87-143+).
    # For each resolved segment: when a rule is supplied and nothing has matched
    # yet, walk the segment's rules — a {RuleError} sentinel short-circuits and
    # propagates out. On a match (or when no rule was supplied) append the segment
    # id unless already stored. A non-empty append is persisted via {#put_segments}.
    def set_custom_segments(visitor_id, segments, segment_rule)
      existing = stored_custom_segments(visitor_id)
      segment_ids = [] #: Array[String]
      matched = false #: (bool | Sentinel)

      segments.each do |segment|
        if segment_rule && matched != true
          matched = @rule_manager.is_rule_matched(segment_rule, segment["rules"], "ConfigSegment ##{segment["id"]}")
          return matched if matched.is_a?(Sentinel)
        end

        next unless !segment_rule || matched == true

        append_segment_id(segment, existing, segment_ids)
      end

      persist_custom_segments(visitor_id, existing, segment_ids)
    end

    # Append +segment["id"]+ (stringified) to the pending list unless it is already
    # stored or already pending; an already-stored id warns (JS
    # +CUSTOM_SEGMENTS_KEY_FOUND+).
    def append_segment_id(segment, existing, segment_ids)
      id = segment["id"]&.to_s
      return if id.nil?

      if existing.include?(id)
        @log_manager&.warn("SegmentsManager#set_custom_segments: custom segment id #{id} already stored")
      elsif !segment_ids.include?(id)
        segment_ids << id
      end
    end

    # Persist the newly-matched ids (appended to the existing list) into
    # +StoreData["segments"]["customSegments"]+, or no-op + debug when nothing
    # matched (JS +SEGMENTS_NOT_FOUND+). Returns the persisted segments hash or nil.
    def persist_custom_segments(visitor_id, existing, segment_ids)
      if segment_ids.empty?
        @log_manager&.debug("SegmentsManager#set_custom_segments: no segments matched")
        return nil
      end

      segments_data = { CUSTOM_SEGMENTS => existing + segment_ids }
      put_segments(visitor_id, segments_data)
      segments_data
    end

    # The visitor's currently-stored +customSegments+ id list (or +[]+), read from
    # +StoreData["segments"]+ through the store seam.
    def stored_custom_segments(visitor_id)
      key = @data_store_manager.visitor_key(account_id, project_id, visitor_id)
      stored = @data_store_manager.get(key)
      segments = stored.is_a?(Hash) ? stored["segments"] : nil
      list = segments.is_a?(Hash) ? segments[CUSTOM_SEGMENTS] : nil
      list.is_a?(Array) ? list : []
    end

    # Atomically merge a report-segments partial into +StoreData["segments"]+.
    def merge_segments(visitor_id, report_segments)
      @data_store_manager.merge_visitor_data(account_id, project_id, visitor_id) do |_current|
        { "segments" => report_segments }
      end
    end

    # The account / project halves of the visitor store key (coerced to String —
    # nil-safe before any config is installed).
    def account_id
      @account_resolver.call.to_s
    end

    def project_id
      @project_resolver.call.to_s
    end
  end
end
