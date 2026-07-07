# frozen_string_literal: true

module ConvertSdk
  # The per-visitor public surface — THE object an integrator holds for the
  # lifetime of one web request or background job.
  #
  # A +Context+ is created by {Client#create_context} and binds together one
  # visitor (its id + normalised attributes) and the SDK's shared, injected
  # managers (config, store, events, logging). It is deliberately a *stable
  # shell*: the decisioning methods (+run_experience(s)+, +run_feature(s)+,
  # +run_custom_segments+, +track_conversion+) attach to this class in later
  # stories — this story builds creation, attribute normalisation, property
  # updates, and the two config/visitor-data lookups.
  #
  # == Deep-stringify at the public boundary (FR11)
  #
  # Ruby integrators write symbol keys (+{ country: "US" }+); Rails params arrive
  # string-keyed (+{ "country" => "US" }+). Both must behave identically, so
  # EVERY attribute hash crossing the public boundary (the constructor and
  # {#update_visitor_properties}) is recursively *deep-stringified* ONCE, here —
  # symbol keys become strings through nested hashes and arrays-of-hashes. The
  # internals (and everything written to the store, which is wire-world) then
  # operate EXCLUSIVELY on string keys. Values are never coerced — only keys.
  # (This normalisation has no JS parallel; JS has no symbol-as-hash-key idiom.)
  #
  # == Independence (FR12)
  #
  # Each {Client#create_context} call returns a NEW, independent +Context+. Two
  # contexts for DIFFERENT visitor ids share NO in-memory state — a property
  # update on one never bleeds into the other. Two contexts for the SAME visitor
  # id legitimately share the visitor's +StoreData+ THROUGH the store (that is
  # stickiness, not contamination): in-memory attributes stay per-instance, but
  # persisted properties round-trip via the shared store.
  #
  # == Visitor store key
  #
  # All persisted visitor data lives under the +{account_id}-{project_id}-{visitor_id}+
  # key built by the single 2.1 key builder ({DataStoreManager#visitor_key}); the
  # account / project halves come from the {DataManager} readers. All stored
  # visitor data is string-keyed.
  #
  # == Never-crash boundary (NFR9, architecture verbatim)
  #
  # Every public method wraps its body in +rescue StandardError+ → an +error+ log
  # line (format +Context#method: ...+) + the method's per-contract return value
  # (+nil+ for lookups, +self+ for the chainable mutator). A raising collaborator
  # degrades the call; it never crashes the host request.
  class Context
    # @param visitor_id [String] the resolved visitor id (validated non-blank by
    #   {Client#create_context} before construction).
    # @param attributes [Hash, nil] the per-visitor attributes; deep-stringified
    #   here at the public boundary (nil → +{}+).
    # @param data_manager [DataManager] the config reader surface (backs
    #   {#get_config_entity} and supplies the account/project key halves).
    # @param data_store_manager [DataStoreManager] the persistence port (atomic
    #   visitor-data merge + reads).
    # @param event_manager [EventManager] lifecycle pub/sub (held for the
    #   decisioning methods that land in later stories).
    # @param log_manager [LogManager] the redacting logging surface.
    # @param config [Config] the validated configuration surface.
    # @param experience_manager [ExperienceManager, nil] the variation-selection
    #   surface backing {#run_experience}/{#run_experiences} (Story 2.11). nil
    #   leaves the shell decisioning-less (the 2.8 lookup-only construction).
    # @param feature_manager [FeatureManager, nil] the feature-resolution +
    #   typed-variable-casting surface backing {#run_feature}/{#run_features}
    #   (Story 3.1). nil leaves the feature methods miss-only (no decisioning).
    # @param segments_manager [SegmentsManager, nil] the visitor-segmentation
    #   surface backing {#set_default_segments}/{#run_custom_segments} (Story 3.2).
    #   nil leaves the segmentation methods inert (no persistence).
    # @param api_manager [ApiManager, nil] the outbound delivery surface (Story
    #   4.1). When wired, a fresh bucketing decision enqueues a +bucketing+ event
    #   at the single {#fire_bucketing} seam; nil leaves the enqueue inert.
    def initialize(visitor_id:, data_manager:, data_store_manager:, event_manager:,
                   log_manager:, config:, attributes: nil, experience_manager: nil,
                   feature_manager: nil, segments_manager: nil, api_manager: nil)
      @visitor_id = visitor_id
      @data_manager = data_manager
      @data_store_manager = data_store_manager
      @event_manager = event_manager
      @log_manager = log_manager
      @config = config
      @experience_manager = experience_manager
      @feature_manager = feature_manager
      @segments_manager = segments_manager
      @api_manager = api_manager
      # Deep-stringify the caller's attributes ONCE at the boundary; internals
      # only ever see string keys. nil → empty. The caller's hash is never mutated.
      @attributes = deep_stringify(attributes || {})
      # qs-03 (RB-5) preview state — nil until {#set_preview} succeeds. A plain
      # per-instance ivar (never a class/shared variable): two Contexts NEVER
      # share this (AC7 isolation). Shape: +{experience_id:, variation_id:,
      # experience:, experience_key:}+.
      @preview = nil #: Hash[Symbol, untyped]?
    end

    # @return [String] the visitor id this context is bound to.
    attr_reader :visitor_id

    # @return [Hash{String=>Object}] the in-memory, string-keyed attributes (the
    #   merged view subsequent decision methods read).
    attr_reader :attributes

    # Merge per-visitor properties into BOTH the stored +StoreData+ (atomically,
    # via {DataStoreManager#merge_visitor_data}) and the in-memory attributes, so
    # a later decision on THIS context sees the merge immediately (in-memory) and
    # a later context for the same visitor sees it through the store (stickiness).
    #
    # Properties are deep-stringified at this public boundary and merged under the
    # +StoreData+ +"segments"+ sub-key (JS +updateVisitorProperties+ stores
    # +{segments: props}+ — +context.ts:482+). The merge is atomic per visitor:
    # the read-modify-write runs inside the store manager's merge mutex.
    #
    # == Zero-trace under preview (qs-03 AC6, RB-6)
    #
    # On a preview-active context ONLY the store write below is skipped — the
    # in-memory +@attributes+ merge always applies (JS parity: JS's public
    # +updateVisitorProperties+ has no preview guard of its own, but the
    # PRIVATE helper it calls to persist DOES skip entirely under preview —
    # +context.ts:626-629+, +if (this._preview) return;+ — leaving the
    # in-memory side unaffected there too). "Per-context scratch" per the
    # qs-03 spec: a later decision on THIS context still sees the merge; no
    # trace of it ever reaches the store.
    #
    # @param properties [Hash] the properties to merge (symbol or string keys).
    # @return [self]
    def update_visitor_properties(properties)
      normalised = deep_stringify(properties || {})
      if @preview.nil?
        @data_store_manager.merge_visitor_data(account_key, project_key, @visitor_id) do |_current|
          { "segments" => normalised }
        end
      end
      @attributes = @attributes.merge(normalised)
      self
    rescue StandardError => e
      @log_manager.error("Context#update_visitor_properties: #{e.class}: #{e.message}")
      self
    end

    # Read this visitor's persisted +StoreData+ from the store.
    #
    # Returns the stored, string-keyed +StoreData+ verbatim when present; when the
    # visitor has no stored entry, returns the empty +StoreData+ shape
    # +{"bucketing"=>{}, "segments"=>{}, "goals"=>{}}+ (a Ruby-specific stable
    # shape — JS returns a bare +{}+ — so callers always get the three known
    # sub-maps to read).
    #
    # @return [Hash{String=>Object}] the visitor's StoreData (or the empty shape).
    def get_visitor_data
      key = @data_store_manager.visitor_key(account_key, project_key, @visitor_id)
      stored = @data_store_manager.get(key)
      stored.is_a?(Hash) ? stored : empty_store_data
    rescue StandardError => e
      @log_manager.error("Context#get_visitor_data: #{e.class}: #{e.message}")
      empty_store_data
    end

    # Look up a config entity by key and type from the installed config snapshot.
    #
    # +entity_type+ names the collection — +:experience+ / +:feature+ / +:goal+
    # (accepted as a symbol or a string; the value is matched verbatim after
    # +to_s+, so it must be one of those three lowercase names) — and dispatches
    # to the matching {DataManager} by-key reader. A miss (unknown key OR
    # unknown/unmatched type) returns
    # +nil+ and emits a +debug+ line
    # (+Context#get_config_entity: no {type} found for key={key}+) — never a
    # raise. (JS +getConfigEntity+ — +context.ts:495+ — returns +undefined+
    # silently on a miss; the debug log is a Ruby-specific observability
    # enhancement.)
    #
    # @param key [String] the entity +key+ to look up.
    # @param entity_type [String, Symbol] the collection: experience/feature/goal.
    # @return [Hash, nil] the frozen entity hash, or nil on a miss.
    def get_config_entity(key, entity_type)
      type = entity_type.to_s
      entity =
        case type
        when "experience" then @data_manager.experience_by_key(key)
        when "feature" then @data_manager.feature_by_key(key)
        when "goal" then @data_manager.goal_by_key(key)
        end
      return entity unless entity.nil?

      @log_manager.debug("Context#get_config_entity: no #{type} found for key=#{key}")
      nil
    rescue StandardError => e
      @log_manager.error("Context#get_config_entity: #{e.class}: #{e.message}")
      nil
    end

    # Force a specific variation of an experience for THIS context — bypassing
    # audiences, segments, locations, the environment check, experience status,
    # variation status/traffic filters, stored decisions, and the bucketing
    # hash for that experience only (qs-03 AC4/AC5). Mirrors JS
    # +Context#setPreview+ (+context.ts:143-205+); this Ruby surface is
    # synchronous — the +?exp=+ fallback fetch runs through
    # {ApiManager#get_config_by_experience}, itself process-wide memoized for
    # 60s (qs-03 AC8), so no async/await equivalent is needed here.
    #
    # == Resolution
    #
    # The CURRENT installed config is tried first, by id
    # ({DataManager#experience_by_id}); when absent, a live
    # +?exp={experience_id}+ fetch resolves it instead (never touches the
    # installed config or the store — a previewed experience may be draft/
    # paused and must never be cached alongside production config). The
    # resolved experience is held BY REFERENCE, never duped or rebuilt:
    # DataManager's installed config entities are already deep-frozen (Story
    # 2.7), so simply holding the reference carries none of the JS SDK-7
    # in-place-mutation risk (mutating a frozen Ruby Hash raises
    # +FrozenError+ rather than silently corrupting shared state); a fetched
    # experience is a brand-new object that is never installed anywhere, so it
    # is never shared to begin with.
    #
    # == Inert on bad input (AC7)
    #
    # A blank +experience_id+/+variation_id+, an unresolvable experience
    # (absent from both the installed config and the +?exp=+ fetch response),
    # or an unknown +variation_id+ on the resolved experience all leave preview
    # state UNSET (a +warn+ log, never a raise) — a subsequent
    # {#run_experience} on this context decides exactly as if this method had
    # never been called.
    #
    # == Isolation (AC7)
    #
    # Preview state lives on THIS +Context+ instance only (a plain ivar) — two
    # +Context+s, even for the same client/config, never share it.
    #
    # Never raises into the host: an internal failure degrades to an +error+
    # log + leaves preview state unset (NFR9).
    #
    # @param experience_id [String] the previewed experience's +id+.
    # @param variation_id [String] the variation +id+ to force.
    # @return [self]
    def set_preview(experience_id:, variation_id:)
      return warn_preview_inert("experience_id/variation_id required") if blank?(experience_id) || blank?(variation_id)

      experience = resolve_preview_experience(experience_id)
      return warn_preview_inert("no experience found for id=#{experience_id}") if experience.nil?

      decision = @data_manager.get_preview_decision(experience, variation_id)
      return warn_preview_inert("no variation found for id=#{variation_id}") if decision.nil?

      @preview = {
        experience_id: experience_id, variation_id: variation_id,
        experience: experience, experience_key: experience["key"]
      }
      self
    rescue StandardError => e
      @log_manager.error("Context#set_preview: #{e.class}: #{e.message}")
      self
    end

    # Decide a single experience for this visitor and return its variation.
    #
    # The optional per-call +attributes+ are deep-stringified and merged OVER the
    # context's own attributes (per-call wins), then handed to the ordered
    # decision flow ({ExperienceManager#select_variation} -> {DataManager}). On a
    # hit a frozen {BucketedVariation} is returned and the {SystemEvents::BUCKETING}
    # lifecycle event fires (payload +{visitor_id, experience_key, variation_key}+,
    # deferred for late subscribers — JS context.ts:153-162). On a miss the
    # matching {Sentinel} ({RuleError}/{BucketingError}) is returned and NO event
    # fires. The integrator pattern works on both:
    #
    #   case (v = context.run_experience("homepage-test")).key
    #   when nil then render_default          # a sentinel miss (key is nil)
    #   else          render_variation(v.key) # a real decision
    #   end
    #
    # Never raises into the host: an internal failure degrades to
    # {RuleError::NO_DATA_FOUND} + an +error+ log (NFR9).
    #
    # == Tracking control (Story 4.5)
    #
    # +attributes[:enable_tracking]+ (or +"enable_tracking"+) is the per-call
    # tracking switch (snake_case of the JS +BucketingAttributes.enableTracking+).
    # When +false+ THIS call still decides and still persists sticky StoreData, but
    # NO bucketing event is enqueued (a +debug+ line records the suppression). The
    # global Config +tracking: false+ switch ALWAYS wins over a per-call +true+.
    #
    # == Preview forcing (qs-03 AC4/AC5)
    #
    # When {#set_preview} has forced a variation for THIS +key+ on this context,
    # that forced decision is returned DIRECTLY — bypassing decisioning entirely
    # (no audience/location/environment/status/traffic/stored-decision/bucketing
    # walk) and firing NO {SystemEvents::BUCKETING} event (mirrors JS
    # +context.ts:228-235+). Because this check runs FIRST, it naturally takes
    # precedence over a stored decision or fresh bucketing for that experience;
    # every OTHER experience on this same context still decides normally.
    #
    # == Zero-trace on OTHER experiences under preview (qs-03 AC6, RB-6)
    #
    # When THIS context has a preview active but +key+ is NOT the previewed
    # experience, decisioning proceeds NORMALLY — only tracking/persistence are
    # suppressed: {#decision_attributes} threads +enable_storage: false+ so
    # {DataManager#persist_bucketing} never writes sticky StoreData, and the
    # per-call tracking verdict is forced +false+ so {#fire_bucketing}'s
    # {#suppress_bucketing_enqueue?} skips the outbound enqueue. A deliberate
    # Ruby/JS divergence: JS (+context.ts:260+) ALSO wraps the
    # {SystemEvents::BUCKETING} lifecycle-event fire in +if (!this._preview)+;
    # Ruby's {#fire_bucketing} doc (Story 4.5) establishes that event as pure
    # decisioning observability, orthogonal to the tracking switch — so it
    # ALWAYS fires here too, preview or not. Zero-trace is defined over track
    # REQUESTS + STORE writes, not the in-process pub/sub event.
    #
    # @param key [String] the experience +key+.
    # @param attributes [Hash, nil] optional per-call visitor properties merged
    #   over the context attributes (deep-stringified). May carry +:enable_tracking+.
    # @return [BucketedVariation, Sentinel] a frozen variation or a sentinel miss.
    def run_experience(key, attributes = nil)
      manager = @experience_manager
      return RuleError::NO_DATA_FOUND if manager.nil?

      preview = @preview
      return forced_preview_variation(preview) if preview && key == preview[:experience_key]

      @data_manager.ensure_fresh_config!
      variation = manager.select_variation(@visitor_id, key, decision_attributes(attributes))
      track = preview.nil? && tracking_enabled_for_call?(attributes)
      fire_bucketing(key, variation, track: track) unless variation.is_a?(Sentinel)
      variation
    rescue StandardError => e
      @log_manager.error("Context#run_experience: #{e.class}: #{e.message}")
      RuleError::NO_DATA_FOUND
    end

    # Decide ALL applicable (running) experiences for this visitor and return the
    # list of bucketed variations (FR16). Misses are FILTERED OUT (JS parity —
    # experience-manager.ts:159-168): the list contains ONLY frozen
    # {BucketedVariation}s the visitor was actually bucketed into, never sentinels.
    # The {SystemEvents::BUCKETING} event fires once per returned variation
    # (JS context.ts:209-222).
    #
    #   context.run_experiences.each { |v| activate(v.experience_key, v.key) }
    #
    # Never raises into the host: an internal failure degrades to +[]+ + an
    # +error+ log (NFR9).
    #
    # +attributes[:enable_tracking] == false+ suppresses the per-variation bucketing
    # enqueue for THIS call (decisioning + sticky writes unaffected); the global
    # Config +tracking: false+ switch always wins (Story 4.5).
    #
    # On a preview-active context (qs-03 AC6, RB-6) every decided variation here
    # (none of which can be the previewed experience — {#run_experience} is the
    # ONLY forced-decision path) is zero-trace exactly like {#run_experience}'s
    # OTHER-experience branch: {#decision_attributes} suppresses the sticky
    # persist and the per-variation tracking verdict is forced +false+. The
    # {SystemEvents::BUCKETING} event still fires per variation (see
    # {#run_experience}'s doc for the Ruby/JS divergence rationale).
    #
    # @param attributes [Hash, nil] optional per-call visitor properties merged
    #   over the context attributes (deep-stringified). May carry +:enable_tracking+.
    # @return [Array<BucketedVariation>] the frozen variations (misses excluded).
    def run_experiences(attributes = nil)
      manager = @experience_manager
      return [] if manager.nil?

      @data_manager.ensure_fresh_config!
      variations = manager.select_variations(@visitor_id, decision_attributes(attributes))
      track = @preview.nil? && tracking_enabled_for_call?(attributes)
      variations.each { |variation| fire_bucketing(variation.experience_key, variation, track: track) }
      variations
    rescue StandardError => e
      @log_manager.error("Context#run_experiences: #{e.class}: #{e.message}")
      []
    end

    # Evaluate a SINGLE feature flag for this visitor with typed variables (FR24).
    #
    # The feature resolves THROUGH experience bucketing (FR26): it is ENABLED
    # exactly when the visitor is bucketed (via the Story 2.11 decision flow) into
    # a variation carrying that feature, and its variables arrive cast to their
    # declared types (FR27 — see {FeatureManager#cast_type}). On a hit a frozen
    # {BucketedFeature} (+status: enabled+) is returned; when the same feature is
    # carried by SEVERAL bucketed variations an Array of enabled {BucketedFeature}s
    # is returned (JS +runFeature+ parity). On a miss — feature undeclared, or the
    # visitor bucketed into no carrying variation — a frozen DISABLED
    # {BucketedFeature} is returned, never an exception (AC#5).
    #
    # Branch on +#status+ (never an error sentinel):
    #
    #   feature = context.run_feature("new-checkout")
    #   if feature.status == ConvertSdk::FeatureStatus::ENABLED
    #     render_new_checkout(feature.variables["headline"])
    #   else
    #     render_legacy_checkout
    #   end
    #
    # NOTE (accepted parity break): JS +runFeature+ accepts an optional
    # +experienceKeys+ filter argument; this Ruby surface intentionally OMITS it
    # (deferred feature). Resolution always spans all configured experiences.
    #
    # Never raises into the host: an internal failure degrades to a DISABLED
    # {BucketedFeature} (carrying the requested key) + an +error+ log (NFR9).
    #
    # @param key [String] the feature +key+ to evaluate.
    # @param attributes [Hash, nil] optional per-call visitor properties merged
    #   over the context attributes (deep-stringified).
    # @return [BucketedFeature, Array<BucketedFeature>] the resolved feature(s).
    def run_feature(key, attributes = nil)
      manager = @feature_manager
      return disabled_feature(key) if manager.nil?

      @data_manager.ensure_fresh_config!
      manager.run_feature(@visitor_id, key, decision_attributes(attributes))
    rescue StandardError => e
      @log_manager.error("Context#run_feature: #{e.class}: #{e.message}")
      disabled_feature(key)
    end

    # Evaluate ALL declared feature flags for this visitor with typed variables
    # (FR25). Returns the full feature roster: every feature carried by a variation
    # the visitor was bucketed into is ENABLED (variables cast to declared types);
    # every other declared feature is DISABLED (JS +runFeatures+ parity, no feature
    # filter). Misses never surface as exceptions or error sentinels.
    #
    #   context.run_features.each do |feature|
    #     toggle(feature.key, on: feature.status == ConvertSdk::FeatureStatus::ENABLED)
    #   end
    #
    # Never raises into the host: an internal failure degrades to +[]+ + an
    # +error+ log (NFR9).
    #
    # @param attributes [Hash, nil] optional per-call visitor properties merged
    #   over the context attributes (deep-stringified).
    # @return [Array<BucketedFeature>] the resolved features (enabled + disabled).
    def run_features(attributes = nil)
      manager = @feature_manager
      return [] if manager.nil?

      @data_manager.ensure_fresh_config!
      manager.run_features(@visitor_id, decision_attributes(attributes))
    rescue StandardError => e
      @log_manager.error("Context#run_features: #{e.class}: #{e.message}")
      []
    end

    # Set default report-segments for this visitor (FR28; JS +setDefaultSegments+
    # -> +SegmentsManager#put_segments+, +context.ts:434-436+). The supplied
    # segments are deep-stringified at this public boundary, then filtered to the
    # seven JS {SegmentsManager::SEGMENTS_KEYS} report keys and merged into the
    # visitor's +StoreData["segments"]+ (non-report keys are dropped). Caller
    # supplies the JS wire keys (+visitorType+, +customSegments+, …) — these ARE
    # the public contract (FR30); the diverged PHP variants are never produced.
    #
    # NO lifecycle event fires on segment attachment (JS parity — neither
    # +setDefaultSegments+ nor +runCustomSegments+ fire +SystemEvents.SEGMENTS+).
    #
    # == Zero-trace under preview (qs-03 AC6, RB-6)
    #
    # +enable_storage: @preview.nil?+ threads through to
    # {SegmentsManager#put_segments}, suppressing ONLY the persistence write
    # (mirrors JS SDK-6, +context.ts:571+ — +!this._preview+ passed the same way).
    #
    # Never raises into the host: a failure degrades to an +error+ log and returns
    # +self+ (NFR9).
    #
    # @param segments [Hash] the candidate report-segments (symbol or string keys).
    # @return [self]
    def set_default_segments(segments)
      manager = @segments_manager
      return self if manager.nil?

      manager.put_segments(@visitor_id, deep_stringify(segments || {}), enable_storage: @preview.nil?)
      self
    rescue StandardError => e
      @log_manager.error("Context#set_default_segments: #{e.class}: #{e.message}")
      self
    end

    # Evaluate the named custom segments for this visitor and attach the matching
    # segment ids (FR29; JS +runCustomSegments+, +context.ts:455-475+). For each
    # key the {SegmentsManager} looks up the segment entity and evaluates its rules
    # — via the Epic 2 {RuleManager} — against the visitor's properties (the
    # context attributes deep-merged with the stored segments and the per-call
    # +ruleData+, mirroring JS +getVisitorProperties+). Matching ids attach under
    # +customSegments+ in +StoreData+. A surfaced {RuleError} sentinel is returned
    # verbatim; otherwise +nil+ (JS returns the +RuleError+ union or +undefined+).
    #
    # NO lifecycle event fires on attachment (JS parity, F-014).
    #
    # == Zero-trace under preview (qs-03 AC6, RB-6)
    #
    # +enable_storage: @preview.nil?+ threads through to
    # {SegmentsManager#select_custom_segments}, suppressing ONLY the persistence
    # write — rule MATCHING still runs exactly as normal (mirrors JS SDK-6,
    # +context.ts:610+ — +!this._preview+ passed the same way).
    #
    # Never raises into the host: a failure degrades to an +error+ log + +nil+ (NFR9).
    #
    # @param segment_keys [Array<String>] the segment keys to evaluate.
    # @param attributes [Hash, nil] optional +{ruleData: {...}}+ visitor data the
    #   segment rules match against (deep-stringified, merged over the context
    #   attributes); +nil+ uses the context attributes alone.
    # @return [Sentinel, nil] a propagated {RuleError}, or nil.
    def run_custom_segments(segment_keys, attributes = nil)
      manager = @segments_manager
      return nil if manager.nil?

      result = manager.select_custom_segments(
        @visitor_id, segment_keys, visitor_properties(attributes), enable_storage: @preview.nil?
      )
      result.is_a?(Sentinel) ? result : nil
    rescue StandardError => e
      @log_manager.error("Context#run_custom_segments: #{e.class}: #{e.message}")
      nil
    end

    # Track a conversion for this visitor on +goal_key+ with optional revenue /
    # transaction data, deduplicated per visitor per goal (FR31-FR35).
    #
    # The dedup decision + atomic mark live in {DataManager#convert} (the store
    # merge lock makes check-then-mark one atomic op — the Android qs-01 fix);
    # this surface wraps the returned wire-shaped +data+ hash into the
    # +{eventType:'conversion', data:{...}}+ envelope (co-located with the
    # bucketing-event construction site for consistency), enqueues it through the
    # {ApiManager} (per-visitor merge, non-blocking — NFR2), and fires the
    # {SystemEvents::CONVERSION} lifecycle event with +deferred: true+ so a
    # listener that subscribes AFTER the call still receives the replay (JS
    # context.ts:416-424). When the conversion is deduplicated or the goal key is
    # unknown, {DataManager#convert} returns +nil+: no event is enqueued and
    # CONVERSION does NOT fire.
    #
    #   context.track_conversion("purchase", goal_data: { amount: 49.99, transaction_id: "tx-1" })
    #
    # +force_multiple_transactions: true+ bypasses the dedup check (a legitimate
    # repeat transaction is enqueued) without re-marking the goal — see
    # {DataManager#convert}.
    #
    # +goal_data+ accepts the eight {GoalDataKey} platform keys in snake_case
    # symbol form (+amount:+, +products_count:+, +transaction_id:+,
    # +custom_dimension_1:+ … +custom_dimension_5:+); unknown keys are rejected
    # (debug-logged) and emitted as +[{key, value}]+ wire pairs.
    #
    # Never raises into the host: an internal failure degrades to an +error+ log
    # and returns +self+ (NFR9).
    #
    # @param goal_key [String] the goal +key+ to convert on.
    # @param goal_data [Hash, nil] optional revenue/transaction data (snake_case
    #   symbol keys of the eight platform keys).
    # @param force_multiple_transactions [Boolean] bypass the per-goal dedup check.
    # @return [self]
    def track_conversion(goal_key, goal_data: nil, force_multiple_transactions: false)
      # qs-03 (RB-6) — zero-trace: a preview-active context is a FULL no-op here,
      # checked BEFORE the global tracking gate below (and BEFORE
      # DataManager#convert) so NOTHING happens — no enqueue, no CONVERSION
      # event, and no dedup mark (the mark lives inside #convert's atomic
      # dedup-and-mark, never reached). Mirrors JS +context.ts:512-519+
      # (+if (this._preview) return;+ at the top of +trackConversion+).
      return self if @preview

      # Story 4.5 — the global tracking gate sits BEFORE DataManager#convert so a
      # suppressed conversion neither enqueues NOR marks dedup (the goals[goalId]
      # mark lives inside #convert's atomic dedup-and-mark). A subsequent same-goal
      # call therefore stays unblocked until tracking is re-enabled. Return value
      # is unchanged (self); no sentinel.
      unless @config.tracking
        @log_manager.debug("Context#track_conversion: tracking disabled, event suppressed")
        return self
      end

      @data_manager.ensure_fresh_config!
      data = @data_manager.convert(
        @visitor_id, goal_key,
        goal_data: goal_data,
        force_multiple_transactions: force_multiple_transactions
      )
      fire_conversion(goal_key, data) unless data.nil?
      self
    rescue StandardError => e
      @log_manager.error("Context#track_conversion: #{e.class}: #{e.message}")
      self
    end

    private

    # {#set_preview}'s inert-path helper: warn-log +detail+ under the
    # +Context#set_preview+ prefix (the single log-message shape every inert
    # branch shares — AC7) and return +self+ WITHOUT touching +@preview+ (a
    # prior successful preview, if any, is left exactly as it was).
    def warn_preview_inert(detail)
      @log_manager.warn("Context#set_preview: #{detail}")
      self
    end

    # {#run_experience}'s preview-forcing branch: force-decide THIS visitor's
    # previewed variation via {DataManager#get_preview_decision}. +#set_preview+
    # only ever stores a preview whose (experience, variation_id) pair already
    # resolved a decision, and the resolved experience is a frozen Hash that can
    # never drift afterward, so a nil result here is a defensive fallback, not
    # an expected path.
    def forced_preview_variation(preview)
      @data_manager.get_preview_decision(preview[:experience], preview[:variation_id]) || RuleError::NO_DATA_FOUND
    end

    # Resolve the previewed experience for {#set_preview}: the installed
    # config's by-id reader first ({DataManager#experience_by_id}); when
    # absent, the +?exp=+ live-fetch fallback ({#fetch_preview_experience}).
    def resolve_preview_experience(experience_id)
      @data_manager.experience_by_id(experience_id) || fetch_preview_experience(experience_id)
    end

    # The +?exp={experience_id}+ fallback fetch ({ApiManager#get_config_by_experience},
    # process-wide memoized for 60s — qs-03 AC8) for an experience absent from
    # the installed config (e.g. a draft/paused preview target). A nil
    # {ApiManager} (no Client-wired collaborator) or a failed fetch (the port
    # never raises — it degrades to nil) both resolve to a miss here; the
    # response's own +experiences+ collection is scanned by id (+to_s+
    # compared, ids may arrive as different types).
    def fetch_preview_experience(experience_id)
      manager = @api_manager
      return nil if manager.nil?

      config = manager.get_config_by_experience(experience_id)
      return nil unless config.is_a?(Hash)

      experiences = config["experiences"]
      return nil unless experiences.is_a?(Array)

      target = experience_id.to_s
      experiences.find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == target }
    end

    # True for +nil+ or a (post-+#strip+) empty String — the blank-input guard
    # for {#set_preview}'s +experience_id+/+variation_id+ (mirrors
    # {Client#create_context}'s blank +visitor_id+ guard).
    def blank?(value)
      value.nil? || (value.respond_to?(:strip) && value.strip.empty?)
    end

    # The single conversion seam (mirrors {#fire_bucketing}): enqueue the
    # wire-shaped event THEN fire the lifecycle event with +deferred: true+ (late
    # subscribers replay — JS context.ts:416-424). Fired on SUCCESS only (the
    # caller skips this when {DataManager#convert} returned nil).
    def fire_conversion(goal_key, data)
      enqueue_conversion_event(data)
      @event_manager.fire(
        SystemEvents::CONVERSION,
        { visitor_id: @visitor_id, goal_key: goal_key },
        nil,
        deferred: true
      )
    end

    # Wrap the {DataManager#convert} wire-shaped +data+ hash into the conversion
    # event envelope and enqueue it (no-op when no {ApiManager} is wired).
    # Co-located with {#enqueue_bucketing_event}: both wire-shape at construction
    # time; the ApiManager remains the only payload BUILDER. The visitor's stored
    # report-segments ride the queue's first entry (passed nil when empty so the
    # wire entry omits +segments+) — same convention as the bucketing event.
    def enqueue_conversion_event(data)
      manager = @api_manager
      return if manager.nil?

      event = { "eventType" => SystemEvents::CONVERSION, "data" => data }
      stored_segments = get_visitor_data["segments"]
      segments = stored_segments.is_a?(Hash) && !stored_segments.empty? ? stored_segments : nil
      manager.enqueue(@visitor_id, event, segments: segments)
    end

    # Build the visitor properties the segment rules match against — JS
    # +getVisitorProperties+ (+context.ts:569-577+): the stored segments deep-merged
    # UNDER the context attributes deep-merged with the per-call +ruleData+. The
    # per-call +ruleData+ (and context attributes) win over stored segments. All
    # deep-stringified to string keys (the rule engine reads string keys).
    def visitor_properties(attributes)
      rule_data = attributes.is_a?(Hash) ? (attributes[:ruleData] || attributes["ruleData"]) : nil
      empty = {} #: Hash[String, untyped]
      merged = @attributes.merge(deep_stringify(rule_data || empty))
      stored = get_visitor_data["segments"]
      stored = empty unless stored.is_a?(Hash)
      stored.merge(merged)
    end

    # A frozen DISABLED {BucketedFeature} carrying the requested key — the miss /
    # internal-failure return for {#run_feature} (never an exception, AC#5).
    def disabled_feature(key)
      BucketedFeature.new(key: key, status: FeatureStatus::DISABLED)
    end

    # Build the bucketing-attributes hash for the decision flow: the context
    # attributes deep-merged with the deep-stringified per-call attributes
    # (per-call wins). The merged map is the +visitor_properties+ that drive the
    # AUDIENCE step. +location_properties+ are a SEPARATE optional attribute (JS
    # context.ts:135-143 spreads only an explicit +attributes.locationProperties+;
    # it never defaults location matching to the visitor properties) — supplied
    # only when the caller passes +location_properties+/+"location_properties"+.
    # +environment+ is lifted out so the flow's environment-match step sees it.
    #
    # +enable_storage: @preview.nil?+ (qs-03 / RB-6 zero-trace) rides along on
    # EVERY decision built through this ONE seam — {#run_experience},
    # {#run_experiences}, {#run_feature}, and {#run_features} all call it — so a
    # preview-active context's ENTIRE decisioning surface (not just experiences)
    # never persists sticky StoreData ({DataManager#persist_bucketing}'s gate).
    # Absent preview (the overwhelming default), this is always +true+ —
    # byte-identical to the pre-qs-03 behavior.
    def decision_attributes(per_call)
      merged = @attributes.merge(deep_stringify(per_call || {}))
      {
        visitor_properties: merged,
        location_properties: merged["location_properties"],
        environment: merged["environment"],
        enable_storage: @preview.nil?
      }
    end

    # The single named seam fired once per fresh/decided variation. It does TWO
    # things at this one site (Story 2.11 fired the lifecycle event; Story 4.1
    # completes the deferred enqueue here — never a SECOND fire):
    #
    # 1. Fires the {SystemEvents::BUCKETING} lifecycle event (deferred so late
    #    subscribers are replayed).
    # 2. Enqueues the wire-shaped +bucketing+ event into the {ApiManager} queue
    #    (when one is wired) so {Client#flush} delivers it — string-keyed camelCase
    #    +{eventType:'bucketing', data:{experienceId, variationId}}+. The visitor's
    #    stored report-segments ride on the queue's first entry (JS parity —
    #    data-manager.ts:692-694); an empty segments map is passed as +nil+ so the
    #    wire entry omits the +segments+ key entirely.
    #
    # The SOLE bucketing enqueue site. The {SystemEvents::BUCKETING} LIFECYCLE event
    # ALWAYS fires (it is decisioning observability, not tracking — a host listener
    # may need to react to the decision even under consent denial); only the
    # outbound ENQUEUE is gated by the tracking switch (Story 4.5). +track+ is the
    # composed verdict ({#tracking_enabled_for_call?} — global AND per-call); when +false+
    # the wire enqueue is suppressed with a +debug+ line and stickiness/decisioning
    # are untouched. Contained — a raising listener never crosses back (EventManager
    # swallows it); the enqueue is pure in-memory and inert when no ApiManager is wired.
    def fire_bucketing(experience_key, variation, track: true)
      @event_manager.fire(
        SystemEvents::BUCKETING,
        { visitor_id: @visitor_id, experience_key: experience_key, variation_key: variation.key },
        nil,
        deferred: true
      )
      return if suppress_bucketing_enqueue?(track)

      enqueue_bucketing_event(variation)
    end

    # The composed tracking verdict for THIS bucketing enqueue: suppressed when the
    # global Config switch is off OR the per-call +track+ flag is false. Emits the
    # matching +debug+ suppression line (global vs per-call) so every suppressed
    # enqueue is observable (FR56). Returns true when the enqueue must be skipped.
    def suppress_bucketing_enqueue?(track)
      unless @config.tracking
        @log_manager.debug("Context#run_experience: tracking disabled, event suppressed")
        return true
      end
      unless track
        @log_manager.debug("Context#run_experience: tracking suppressed for call")
        return true
      end
      false
    end

    # Read the per-call +enable_tracking+ switch from the per-call attributes
    # (symbol or string key; the public boundary accepts both — FR11). Absent =>
    # +true+ (tracking on by default). Only +false+ (an explicit per-call opt-out)
    # suppresses; any other value leaves tracking on. The global Config switch is
    # composed separately in {#suppress_bucketing_enqueue?} (global-off always wins).
    def tracking_enabled_for_call?(attributes)
      return true unless attributes.is_a?(Hash)

      value = attributes.fetch(:enable_tracking) { attributes.fetch("enable_tracking", true) }
      value != false
    end

    # Enqueue the wire-shaped bucketing event for the decided variation (no-op when
    # no {ApiManager} is wired). The event keys are camelCase strings sourced from
    # the {BucketedVariation} value object; segments ride from the visitor's
    # StoreData (passed as nil when empty so the wire entry omits them).
    def enqueue_bucketing_event(variation)
      manager = @api_manager
      return if manager.nil?

      event = {
        "eventType" => SystemEvents::BUCKETING,
        "data" => {
          "experienceId" => variation.experience_id,
          "variationId" => variation.id
        }
      }
      stored_segments = get_visitor_data["segments"]
      segments = stored_segments.is_a?(Hash) && !stored_segments.empty? ? stored_segments : nil
      manager.enqueue(@visitor_id, event, segments: segments)
    end

    # The account half of the visitor store key. The {DataManager} reader is
    # +nil+ before any config is installed (degrade-gracefully, NFR12); coerced
    # to +""+ here so the key builder (which interpolates) gets a String. A
    # pre-config key is degenerate but harmless — there is no config to decide on.
    def account_key
      @data_manager.account_id.to_s
    end

    # The project half of the visitor store key (see {#account_key}).
    def project_key
      @data_manager.project_id.to_s
    end

    # The empty +StoreData+ shape returned when a visitor has no persisted data.
    def empty_store_data
      { "bucketing" => {}, "segments" => {}, "goals" => {} }
    end

    # Recursively normalise a (possibly symbol-keyed) hash/array graph to string
    # keys — the public-boundary normalisation (FR11). Only KEYS are stringified;
    # values pass through unchanged. The caller's original graph is never mutated.
    def deep_stringify(node)
      case node
      when Hash
        result = {} #: Hash[String, untyped]
        node.each { |k, v| result[k.to_s] = deep_stringify(v) }
        result
      when Array
        node.map { |element| deep_stringify(element) }
      else
        node
      end
    end
  end
end
