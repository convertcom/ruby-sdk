# frozen_string_literal: true

require "json"

module ConvertSdk
  # The in-memory home of the project configuration snapshot and the ONLY
  # surface through which config is read.
  #
  # +DataManager+ owns the project config as a *deep-frozen, string-keyed*
  # snapshot (architecture Decision 5). Config arrives from one of two places —
  # a live fetch (+GET {config_endpoint}/config/{sdkKey}+) or a developer-supplied
  # +data:+ object — and in BOTH cases it is installed identically through
  # {#install_config}: recursively frozen, then atomically swapped behind
  # +@config_mutex+. Because each installed snapshot is a brand-new frozen object
  # graph, decision paths read it LOCK-FREE (no per-read mutex): a reader either
  # sees the whole previous snapshot or the whole new one, never a torn mix.
  # Only install/swap takes the mutex.
  #
  # == No raw config hash crosses the boundary
  #
  # The parsed config envelope is wrapped here and exposed ONLY through
  # hand-written reader methods (+#experiences+, +#feature_by_key(key)+, …) that
  # return frozen sub-hashes / arrays. There is no public accessor for the raw
  # snapshot and no OpenAPI codegen — the reader inventory is derived by hand
  # from the actual config wire shape (the vendored +test-config.json+ fixture).
  #
  # == Wire shape
  #
  # The config envelope is +{"environment" => ..., "data" => {...}}+; the entity
  # collections (+experiences+, +features+, +goals+, +audiences+, +segments+,
  # optional +locations+) plus +account_id+ and the +project+ sub-hash live under
  # +"data"+. +#project_id+ is +data.project.id+. Readers tolerate sparse or
  # absent keys (return +nil+ / +[]+) so a partial config never crashes a reader.
  #
  # == Degrade-gracefully (NFR12)
  #
  # Before any config is installed every reader returns a sentinel (+nil+ for
  # scalars / by-key lookups, +[]+ for collections) and {#config_available?} is
  # +false+. The client constructs successfully even when the first fetch fails;
  # decision methods (Story 2.11) key off these sentinels.
  #
  # == Config caching & TTL bookkeeping (Story 2.7)
  #
  # Every successful install ALSO writes the config through to the injected
  # {DataStoreManager} under +convert_sdk.config.{sdkKey}+ (2.1's single key
  # builder) wrapped as +{"config" => envelope, "fetched_at" => wall_clock}+.
  # The store has no native TTL, so a *wall-clock* +fetched_at+ is stored for
  # cross-process staleness (a Redis-backed cold start can serve a fresh shared
  # entry without fetching). Independently, an in-process *monotonic* timestamp
  # ({#install_config} records it via the injected +clock+) drives the
  # decision-time TTL check ({#ensure_fresh_config!}) so wall-clock jumps can
  # never expire a live snapshot. Monotonic for in-process TTL, wall-clock for
  # the cross-process cache entry — two clocks, two purposes.
  #
  # == Lazy-TTL fallback (timer-off mode)
  #
  # When the background refresh timer is disabled (+data_refresh_interval: nil+),
  # {#ensure_fresh_config!} performs an on-demand staleness check at decision
  # entry points (PHP semantics): a snapshot older than +ttl+ triggers a
  # synchronous refetch (via the injected +refetch+ callable) BEFORE deciding;
  # a failed refetch keeps serving the stale snapshot (the callable warns). The
  # refetch is guarded by a SEPARATE +@fetch_mutex+ (NOT the config mutex), so
  # concurrent stale deciders collapse to ONE fetch (thundering-herd guard) and
  # the HTTP I/O never holds the config mutex.
  class DataManager
    # @param log_manager [LogManager] injected logger for install diagnostics.
    # @param data_store_manager [DataStoreManager, nil] persistence port for the
    #   config cache write; nil disables the write (standalone unit construction).
    # @param config_key [String, nil] the cache key +convert_sdk.config.{sdkKey}+
    #   (built once by {DataStoreManager#config_key}); nil disables the cache.
    # @param ttl [Numeric, nil] the configured +data_refresh_interval+ in seconds.
    #   A non-nil value is timer-ON mode (the background timer keeps config fresh,
    #   so {#ensure_fresh_config!} is a no-op); +nil+ is timer-OFF mode (Lambda /
    #   CLI), which enables the decision-time on-demand refetch and falls the
    #   effective staleness threshold back to {ConvertSdk::DEFAULT_CONFIG_TTL}
    #   (timer-off ≠ TTL-off). The timer-off mode is thus derived from +ttl.nil?+.
    # @param clock [#call] a monotonic time source (seconds, Float) for in-process
    #   TTL math; defaults to +Process.clock_gettime(Process::CLOCK_MONOTONIC)+.
    # @param refetch [#call, nil] a callable performing one full refresh cycle
    #   (HTTP refetch + install + warn-on-failure) for the synchronous timer-off
    #   path; injected by {Client} after construction (it owns the HTTP I/O and
    #   the lifecycle event). Invoked under the thundering-herd fetch mutex.
    # @param bucketing_manager [BucketingManager, nil] the pure-math variation
    #   selector (Story 2.9); the decision flow's traffic-allocation step uses it.
    #   nil leaves the manager config-read-only (Story 2.5/2.7 standalone use).
    # @param rule_manager [RuleManager, nil] the audience/location rule walker
    #   (Story 2.10). nil leaves the manager config-read-only.
    # @param account_resolver [#call, nil] returns the account id for the visitor
    #   store key; defaults to {#account_id} (the live config reader). Injectable
    #   so a Context can supply its own resolution without re-reading config.
    # @param project_resolver [#call, nil] returns the project id for the visitor
    #   store key; defaults to {#project_id}.
    def initialize(log_manager:, data_store_manager: nil, config_key: nil, ttl: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, refetch: nil,
                   bucketing_manager: nil, rule_manager: nil,
                   account_resolver: nil, project_resolver: nil)
      @log_manager = log_manager
      @data_store_manager = data_store_manager
      @config_key = config_key
      @ttl = ttl
      # Timer-off (Lambda/CLI) mode is exactly "no refresh interval configured".
      @timer_off = ttl.nil?
      @clock = clock
      @refetch = refetch
      # Decision-flow collaborators (Story 2.11). Config-read-only when absent.
      @bucketing_manager = bucketing_manager
      @rule_manager = rule_manager
      @account_resolver = account_resolver || -> { account_id }
      @project_resolver = project_resolver || -> { project_id }
      # The deep-frozen config envelope, or nil before the first install. Read
      # lock-free by every reader; replaced atomically under @config_mutex.
      @config = nil #: Hash[String, untyped]?
      # The monotonic timestamp of the live snapshot's install, or nil pre-config.
      @fetched_at = nil #: Float?
      # Thread safety: guarded by @config_mutex (install/swap + @fetched_at).
      @config_mutex = Thread::Mutex.new
      # Thundering-herd guard for the synchronous timer-off refetch — a SEPARATE
      # mutex so the HTTP refetch never holds the config mutex.
      @fetch_mutex = Thread::Mutex.new
    end

    # The synchronous timer-off refresh callable, injected by {Client} after
    # construction (Client owns the single HTTP port and the lifecycle event).
    # Performs one full refresh cycle (refetch + install + warn-on-failure).
    # @return [#call, nil]
    attr_accessor :refetch

    # Install a parsed config envelope as the live snapshot.
    #
    # The hash is deep-frozen (a fresh recursively-frozen copy — the caller's
    # input is never mutated) and atomically swapped in behind +@config_mutex+.
    # A nil/non-Hash argument is rejected (logged) and leaves the current
    # snapshot intact — install must never crash the host.
    #
    # The first-vs-subsequent determination is made ATOMICALLY inside
    # +@config_mutex+ alongside the swap: the +ready+-once guard (Story 2.5) and
    # the +config.updated+ refresh signal (Story 2.7) both key off the returned
    # marker, so exactly one install in the manager's lifetime is +:first+ even
    # under concurrent installs.
    #
    # @param hash [Hash{String=>Object}] the parsed config envelope
    #   (+{"environment" => ..., "data" => {...}}+).
    # @return [Symbol, false] +:first+ on the first successful install,
    #   +:updated+ on any subsequent install, or +false+ when the argument was
    #   rejected (non-Hash) and no swap happened.
    def install_config(hash)
      unless hash.is_a?(Hash)
        @log_manager.warn("DataManager#install_config: ignored non-Hash config (#{hash.class})")
        return false
      end

      frozen = deep_freeze(hash)
      now = @clock.call
      first = @config_mutex.synchronize do
        was_absent = @config.nil?
        @config = frozen
        @fetched_at = now
        was_absent
      end
      cache_config(frozen)
      @log_manager.info("DataManager#install_config: config installed")
      first ? :first : :updated
    end

    # Install a non-stale cached config entry from the store as the live snapshot
    # — the cross-process warm-start fallback used by {Client} when the initial
    # fetch fails. The entry is +{"config" => envelope, "fetched_at" => wall}+;
    # it is only installed when its WALL-CLOCK age is within +ttl+ (or the
    # default TTL when +ttl+ is nil — timer-off mode). A stale or absent entry
    # is ignored (returns nil). On a successful install an info line records the
    # cache hit.
    #
    # @return [Symbol, nil] the {#install_config} marker on a fresh cache hit,
    #   or nil when no fresh entry was available.
    def install_from_cache_if_fresh
      entry = cached_entry
      return nil unless entry

      fetched_at = entry["fetched_at"]
      config = entry["config"]
      return nil unless fetched_at.is_a?(Numeric) && config.is_a?(Hash)
      return nil if (Time.now.to_f - fetched_at) > effective_ttl

      marker = install_config(config)
      return nil unless marker.is_a?(Symbol)

      @log_manager.info("DataManager#install_from_cache_if_fresh: serving cached config")
      marker
    end

    # Decision-time TTL check for timer-off mode (AC#3, PHP semantics). When a
    # +ttl+ is configured and the live snapshot is older than it (by the
    # monotonic clock), synchronously refetch via the injected callable BEFORE
    # the caller decides. Guarded by the SEPARATE @fetch_mutex so concurrent
    # stale deciders collapse to ONE fetch; the refetch (HTTP I/O) runs OUTSIDE
    # the config mutex. A failed refetch keeps the stale snapshot (the callable
    # warns). A no-op when no ttl/refetch is wired or the snapshot is fresh.
    # @return [void]
    def ensure_fresh_config!
      return unless @timer_off

      refetch = @refetch
      return if refetch.nil?
      return unless config_stale?

      @fetch_mutex.synchronize do
        # Re-check inside the lock: a racing decider may have refreshed already.
        return unless config_stale?

        # The callable performs the full cycle (refetch + install + warn). On
        # success it installs (advancing @fetched_at, so racing deciders that
        # re-check see fresh); on failure it warns and the stale snapshot stays.
        refetch.call
      end
    end

    # @return [Boolean] true when a snapshot exists and its monotonic age exceeds
    #   the configured ttl (or the default ttl when ttl is nil).
    def config_stale?
      fetched_at = @config_mutex.synchronize { @fetched_at }
      return false if fetched_at.nil?

      (@clock.call - fetched_at) > effective_ttl
    end

    # @return [Boolean] true once a config snapshot has been installed.
    def config_available?
      !@config.nil?
    end

    # @return [String, nil] the account id (+data.account_id+), or nil pre-config.
    def account_id
      data&.fetch("account_id", nil)
    end

    # @return [String, nil] the project id (+data.project.id+), or nil pre-config.
    def project_id
      project&.fetch("id", nil)
    end

    # @return [Hash, nil] the frozen +data.project+ sub-hash, or nil pre-config.
    def project
      data&.fetch("project", nil)
    end

    # @return [Array<Hash>] the frozen experiences array ([] pre-config/absent).
    def experiences
      collection("experiences")
    end

    # @return [Array<Hash>] the frozen features array ([] pre-config/absent).
    def features
      collection("features")
    end

    # @return [Array<Hash>] the frozen goals array ([] pre-config/absent).
    def goals
      collection("goals")
    end

    # @return [Array<Hash>] the frozen audiences array ([] pre-config/absent).
    def audiences
      collection("audiences")
    end

    # @return [Array<Hash>] the frozen segments array ([] pre-config/absent).
    def segments
      collection("segments")
    end

    # @return [Array<Hash>] the frozen locations array ([] pre-config/absent).
    #   Absent in some projects (e.g. the vendored fixture) — nil-safe to [].
    def locations
      collection("locations")
    end

    # @param key [String] the experience +key+ to find.
    # @return [Hash, nil] the frozen experience with that key, or nil.
    def experience_by_key(key)
      find_by_key(experiences, key)
    end

    # @param key [String] the feature +key+ to find.
    # @return [Hash, nil] the frozen feature with that key, or nil.
    def feature_by_key(key)
      find_by_key(features, key)
    end

    # @param key [String] the goal +key+ to find.
    # @return [Hash, nil] the frozen goal with that key, or nil.
    def goal_by_key(key)
      find_by_key(goals, key)
    end

    # @return [Array<String>] the frozen archived-experiences id list ([] absent).
    #   IDs may be Integer or String in the wire shape; compared via +to_s+.
    def archived_experiences
      collection("archived_experiences")
    end

    # ============================ DECISION FLOW =============================
    # The ordered JS decision flow (data-manager.ts:227-720). ENTRY point for a
    # single-experience decision; the across-all-experiences map lives in
    # {ExperienceManager#select_variations}. The step ORDER is JS-pinned (research
    # §Decision-Flow / data-manager.ts:302) and must NOT be reordered:
    #   1. entity lookup  (miss -> RuleError::NO_DATA_FOUND)
    #   2. archived check (archived -> NO_DATA_FOUND)
    #   3. environment match (mismatch -> NO_DATA_FOUND)
    #   4. stored-bucketing lookup (sticky: sets is_bucketed)
    #   5. locations / site_area (EMPTY = unrestricted)
    #   6. audiences (permanent skipped when bucketed; transient always)
    #   7. custom segments
    #   8. traffic allocation + 9. variation selection
    #      (no variation -> BucketingError::VARIATION_NOT_DECIDED)
    # Every miss returns its JS-parity {Sentinel} PAIRED with a debug reason log.
    #
    # @param visitor_id [String] the visitor identifier.
    # @param experience_key [String] the experience +key+ to decide.
    # @param attributes [Hash] +:visitor_properties+, +:location_properties+,
    #   +:environment+, +:update_visitor_properties+.
    # @return [BucketedVariation, Sentinel] a frozen variation or a sentinel miss.
    def get_bucketing(visitor_id, experience_key, attributes = {})
      experience = match_rules_by_field(visitor_id, experience_key, attributes)
      return experience if experience.is_a?(Sentinel)
      return RuleError::NO_DATA_FOUND if experience.nil?

      retrieve_bucketing(visitor_id, experience, attributes)
    end

    private

    # Steps 1-7: resolve the experience and run every eligibility gate up to (but
    # not including) traffic allocation. Returns the matched experience Hash, a
    # {Sentinel} (a propagated {RuleError} from a rule walk), or +nil+ (a plain
    # eligibility miss the caller maps to NO_DATA_FOUND). Mirrors JS
    # +matchRulesByField+ (data-manager.ts:202-471).
    def match_rules_by_field(visitor_id, experience_key, attributes)
      # Steps 1-3 — entity / archived / environment gates (each miss -> nil).
      experience = eligible_experience(experience_key, attributes[:environment])
      return nil if experience.nil?

      # Step 4 — stored-bucketing lookup (sticky). Drives permanent-audience skip.
      is_bucketed = visitor_bucketed?(visitor_id, experience)

      # Step 5 — locations / site_area (empty = unrestricted).
      location_outcome = match_locations(attributes[:location_properties], experience)
      return location_outcome if location_outcome.is_a?(Sentinel)
      return reason_miss(experience, "location not match") unless location_outcome

      # Step 6 — audiences (permanent skipped when bucketed; transient always).
      audiences_outcome = match_audiences(experience, attributes[:visitor_properties], is_bucketed)
      return audiences_outcome if audiences_outcome.is_a?(Sentinel)

      # Step 7 — custom segments. Both must pass to reach variation selection.
      eligible_for_variation(experience, audiences_outcome && custom_segments_matched?(experience, visitor_id))
    end

    # Steps 1-3: the entity / archived / environment eligibility gates. Returns
    # the matched experience Hash, or nil on any gate miss (each miss logs the
    # failed step). Splitting these guards out keeps the step-walk above flat.
    def eligible_experience(experience_key, environment)
      experience = experience_by_key(experience_key)
      if experience.nil?
        @log_manager&.debug("DataManager#match_rules_by_field: no experience found for key=#{experience_key}")
        return nil
      end
      return reason_miss(experience, "experience archived") if archived?(experience)
      return reason_miss(experience, "environment not match") unless environment_match?(experience, environment)

      experience
    end

    # The post-audience/segment terminal: the experience is returned only when the
    # gates passed AND it has variations; otherwise a reason-logged nil.
    def eligible_for_variation(experience, gates_passed)
      return reason_miss(experience, "audience not match") unless gates_passed
      return reason_miss(experience, "variations not found") if variation_list(experience).empty?

      @log_manager&.debug("DataManager#match_rules_by_field: rules matched id=#{experience["id"]}")
      experience
    end

    # Log a flow-step miss naming the failed step and return nil — the single
    # "sentinel + silent is forbidden" pairing site for the plain (non-RuleError)
    # eligibility misses.
    def reason_miss(experience, step)
      @log_manager&.debug("DataManager#match_rules_by_field: #{step} id=#{experience["id"]}")
      nil
    end

    # Steps 4/8/9: return the stored sticky variation if usable, else bucket fresh.
    # Mirrors JS +_retrieveBucketing+ (data-manager.ts:558-720).
    def retrieve_bucketing(visitor_id, experience, attributes)
      sticky = sticky_variation(visitor_id, experience)
      return sticky if sticky

      bucket_fresh(visitor_id, experience, attributes)
    end

    # Step 4 (return path): the stored sticky variation rehydrated from CURRENT
    # config, or nil when there is no stored decision OR the stored variation has
    # drifted out of config (config-drift fallthrough -> caller re-buckets).
    def sticky_variation(visitor_id, experience)
      stored = stored_variation_id(visitor_id, experience)
      return nil if stored.nil?

      experience_id = experience["id"].to_s
      variation = retrieve_variation(experience, stored)
      if variation
        @log_manager&.debug("DataManager#retrieve_bucketing: sticky hit exp=#{experience_id} var=#{stored}")
        return build_bucketed_variation(experience, variation, nil)
      end

      @log_manager&.debug("DataManager#retrieve_bucketing: stored var #{stored} drifted from config — re-bucketing")
      nil
    end

    # Steps 8/9: fresh bucketing through the engine + persistence + rehydration.
    # No covering bucket OR a drifted-out selected id -> VARIATION_NOT_DECIDED.
    def bucket_fresh(visitor_id, experience, attributes)
      experience_id = experience["id"].to_s
      buckets = build_buckets(experience)
      decision = @bucketing_manager&.bucket_for_visitor(buckets, visitor_id, experience_id: experience_id)
      variation_id = decision&.fetch(:variation_id, nil)
      variation = variation_id && retrieve_variation(experience, variation_id)
      if variation.nil?
        @log_manager&.debug("DataManager#retrieve_bucketing: unable to select bucket exp=#{experience_id}")
        return BucketingError::VARIATION_NOT_DECIDED
      end

      persist_bucketing(visitor_id, experience_id, variation_id, attributes)
      @log_manager&.debug("DataManager#retrieve_bucketing: bucketed exp=#{experience_id} var=#{variation_id}")
      build_bucketed_variation(experience, variation, decision&.fetch(:bucketing_allocation, nil))
    end

    # True when +experience.id+ is in the archived-experiences list (to_s match).
    def archived?(experience)
      id = experience["id"].to_s
      archived_experiences.any? { |archived| archived.to_s == id }
    end

    # JS environment-match: +experience.environment ? experience.environment ===
    # env : true+ (singular scalar; skip when the experience declares none).
    def environment_match?(experience, environment)
      experience_env = experience["environment"]
      return true if experience_env.nil? || experience_env == ""

      experience_env == environment
    end

    # Step 4: a visitor is "bucketed" for this experience when a stored variation
    # id exists AND still resolves to a variation in the CURRENT config (a drifted
    # stored id does NOT count as bucketed). Mirrors JS data-manager.ts:280-289.
    def visitor_bucketed?(visitor_id, experience)
      stored = stored_variation_id(visitor_id, experience)
      return false if stored.nil?

      !retrieve_variation(experience, stored).nil?
    end

    # The variation id stored in the visitor's bucketing map for this experience,
    # or nil. Reads the visitor StoreData via the store seam (in-memory, NFR1).
    def stored_variation_id(visitor_id, experience)
      bucketing = visitor_store_data(visitor_id)["bucketing"]
      return nil unless bucketing.is_a?(Hash)

      value = bucketing[experience["id"].to_s]
      value&.to_s
    end

    # Step 5: locations array (by id) OR site_area rules OR unrestricted. Returns
    # true/false, or a propagated {RuleError} sentinel from the site_area walk.
    def match_locations(location_properties, experience)
      return true unless location_properties

      location_ids = experience["locations"]
      return match_location_list(location_properties, location_ids) if location_ids.is_a?(Array) && !location_ids.empty?
      return match_site_area(location_properties, experience["site_area"]) if experience["site_area"]

      @log_manager&.info("DataManager#match_locations: location not restricted")
      true
    end

    # Locations-by-id branch: any attached location whose rules match wins. An
    # empty resolved set is unrestricted (true), mirroring JS data-manager.ts:316.
    def match_location_list(location_properties, location_ids)
      located = items_by_ids(location_ids, locations)
      return true if located.empty?

      located.any? do |location|
        @rule_manager&.is_rule_matched(location_properties, location["rules"], "Location ##{location["id"]}") == true
      end
    end

    # site_area branch: a single rule walk; a propagated {RuleError} sentinel
    # surfaces unchanged, otherwise the boolean match.
    def match_site_area(location_properties, site_area)
      matched = @rule_manager&.is_rule_matched(location_properties, site_area, "SiteArea")
      return matched if matched.is_a?(Sentinel)

      matched == true
    end

    # Step 6: audiences. Empty experience audiences -> unrestricted. Permanent
    # audiences are filtered out once the visitor is bucketed; transient always
    # re-evaluated. +matching_options.audiences == "all"+ requires every checked
    # audience to match; otherwise any match suffices. Returns true/false or a
    # propagated {RuleError} sentinel. Mirrors JS data-manager.ts:350-416.
    def match_audiences(experience, visitor_properties, is_bucketed)
      return true unless visitor_properties

      to_check = audiences_to_check(experience, is_bucketed)
      return true if to_check.empty? # unrestricted (no audiences, or all permanent+bucketed)

      matched = matched_audiences(to_check, visitor_properties)
      return matched if matched.is_a?(Sentinel)

      audiences_verdict?(experience, matched, to_check)
    end

    # Resolve the audiences that gate this call: the experience's attached
    # audiences MINUS permanent ones once the visitor is bucketed (transient
    # always re-evaluated — decided behavior 2026-06-07). Returns [] for the two
    # unrestricted cases (no attached audiences, or every attached audience is
    # permanent and the visitor is bucketed), logging which case applied.
    def audiences_to_check(experience, is_bucketed)
      attached = items_by_ids(experience["audiences"], audiences)
      if attached.empty?
        @log_manager&.info("DataManager#match_audiences: audience not restricted")
        return []
      end

      to_check = attached.reject { |a| is_bucketed && a["type"] == "permanent" }
      @log_manager&.info("DataManager#match_audiences: non-permanent audience not restricted") if to_check.empty?
      to_check
    end

    # Walk each checked audience's rules; collect the matches. A propagated
    # {RuleError} sentinel from any walk short-circuits and is returned as-is.
    def matched_audiences(to_check, visitor_properties)
      matched = [] #: Array[Hash[String, untyped]]
      to_check.each do |audience|
        next unless audience["rules"]

        result = @rule_manager&.is_rule_matched(visitor_properties, audience["rules"], "audience ##{audience["id"]}")
        return result if result.is_a?(Sentinel)

        matched << audience if result == true
      end
      matched
    end

    # ALL mode requires every checked audience matched; otherwise any match passes.
    def audiences_verdict?(experience, matched, to_check)
      if all_match_required?(experience)
        matched.length == to_check.length
      else
        !matched.empty?
      end
    end

    # Step 7: custom segments. The experience's audience ids are matched against
    # the segments collection; a present segment must be in the visitor's stored
    # customSegments list. Empty segments -> unrestricted. Mirrors JS
    # data-manager.ts:417-440 + filterMatchedCustomSegments.
    def custom_segments_matched?(experience, visitor_id)
      audience_ids = experience["audiences"]
      segs = audience_ids.is_a?(Array) ? items_by_ids(audience_ids, segments) : [] #: Array[Hash[String, untyped]]
      if segs.empty?
        @log_manager&.info("DataManager#custom_segments_matched?: segmentation not restricted")
        return true
      end

      custom = custom_segments(visitor_id)
      segs.any? { |seg| seg["id"] && custom.include?(seg["id"]) }
    end

    # The visitor's stored customSegments list (under StoreData segments).
    def custom_segments(visitor_id)
      segments_map = visitor_store_data(visitor_id)["segments"]
      return [] unless segments_map.is_a?(Hash)

      list = segments_map["customSegments"]
      list.is_a?(Array) ? list : []
    end

    # +true+ when the experience requires ALL checked audiences to match.
    def all_match_required?(experience)
      experience.dig("settings", "matching_options", "audiences") == "all"
    end

    # Build the variation=>traffic buckets for the bucketing engine: running
    # variations with positive (or absent -> 100) traffic allocation only. Mirrors
    # JS data-manager.ts:622-637.
    def build_buckets(experience)
      buckets = {} #: Hash[String, (Integer | Float)]
      variation_list(experience).each do |variation|
        next unless bucketable_variation?(variation)

        buckets[variation["id"]] = variation["traffic_allocation"] || 100.0
      end
      buckets
    end

    # The experience's variations as a typed array (untyped elements), or [].
    # Centralizes the +Array(experience["variations"])+ coercion so Steep sees a
    # concrete element type (avoiding a +bot+ block parameter).
    def variation_list(experience)
      list = experience["variations"]
      list.is_a?(Array) ? list : []
    end

    # A variation is bucketable when it is a Hash with an id, is running (or has
    # no status), and has positive (or absent -> 100%) traffic allocation. A
    # zero/negative allocation means a stopped variation (excluded). Mirrors the
    # JS status + traffic filters (data-manager.ts:622-635).
    def bucketable_variation?(variation)
      return false unless variation.is_a?(Hash) && variation["id"]

      status = variation["status"]
      return false if status && status != "running"

      allocation = variation["traffic_allocation"]
      allocation.nil? || (allocation.is_a?(Numeric) && allocation.positive?)
    end

    # Persist the bucketing decision into the visitor's StoreData bucketing map
    # (atomic merge via DataStoreManager). Optionally also stores visitor
    # properties as segments (JS updateVisitorProperties path). In-memory store
    # ops only (NFR1; user-supplied Redis trades the no-disk contract).
    def persist_bucketing(visitor_id, experience_id, variation_id, attributes)
      manager = @data_store_manager
      return if manager.nil?

      visitor_properties = attributes[:visitor_properties]
      update = attributes[:update_visitor_properties]
      manager.merge_visitor_data(@account_resolver.call.to_s, @project_resolver.call.to_s, visitor_id) do |_current|
        partial = { "bucketing" => { experience_id => variation_id } }
        partial["segments"] = visitor_properties if update && visitor_properties.is_a?(Hash)
        partial
      end
    end

    # Read the visitor's StoreData via the store seam, or the empty shape.
    def visitor_store_data(visitor_id)
      manager = @data_store_manager
      return {} if manager.nil?

      key = manager.visitor_key(@account_resolver.call.to_s, @project_resolver.call.to_s, visitor_id)
      stored = manager.get(key)
      stored.is_a?(Hash) ? stored : {}
    end

    # Resolve a variation Hash by id within an experience's variations, or nil.
    def retrieve_variation(experience, variation_id)
      target = variation_id.to_s
      variation_list(experience).find do |variation|
        variation.is_a?(Hash) && variation["id"].to_s == target
      end
    end

    # Build the frozen {BucketedVariation} from the experience + variation config
    # entities (never a raw config hash). Mirrors JS data-manager.ts:706-717.
    def build_bucketed_variation(experience, variation, bucketing_allocation)
      BucketedVariation.new(
        experience_id: experience["id"],
        experience_key: experience["key"],
        experience_name: experience["name"],
        bucketing_allocation: bucketing_allocation,
        id: variation["id"],
        key: variation["key"],
        name: variation["name"],
        status: variation["status"],
        traffic_allocation: variation["traffic_allocation"],
        changes: variation["changes"]
      )
    end

    # Select the entities in +list+ whose +id+ is in +ids+ (to_s match). Mirrors
    # JS getItemsByIds (data-manager.ts:1339-1359).
    def items_by_ids(ids, list)
      return [] unless ids.is_a?(Array)

      wanted = ids.map(&:to_s)
      list.select { |entity| entity.is_a?(Hash) && wanted.include?(entity["id"].to_s) }
    end

    # Write the freshly-installed config through to the store, wrapped with a
    # WALL-CLOCK +fetched_at+ for cross-process staleness. A no-op when no store
    # or key is wired (standalone unit construction). The DataStoreManager
    # contains any store failure (logged), so this never crashes an install.
    def cache_config(frozen)
      store = @data_store_manager
      key = @config_key
      return if store.nil? || key.nil?

      store.set(key, { "config" => frozen, "fetched_at" => Time.now.to_f })
    end

    # Read the raw cache entry from the store, or nil when no store/key is wired
    # or nothing is cached.
    def cached_entry
      store = @data_store_manager
      key = @config_key
      return nil if store.nil? || key.nil?

      entry = store.get(key)
      entry.is_a?(Hash) ? entry : nil
    end

    # The staleness threshold: the configured ttl, or the SDK default (300s) in
    # timer-off mode (ttl nil ≠ TTL-off — Lambda converges on the same cadence).
    def effective_ttl
      @ttl || ConvertSdk::DEFAULT_CONFIG_TTL
    end

    # The frozen +"data"+ sub-hash of the live snapshot, or nil pre-config.
    # Read lock-free: @config is either nil or a fully-frozen graph.
    def data
      @config&.fetch("data", nil)
    end

    # Fetch a frozen collection under +"data"+, defaulting to a frozen empty
    # array when the snapshot or the key is absent.
    def collection(name)
      found = data&.fetch(name, nil)
      found.is_a?(Array) ? found : []
    end

    # Linear scan for the entity whose +"key"+ matches +key+. Entities without a
    # +"key"+ (sparse fixture rows) simply never match. Returns the frozen entity.
    def find_by_key(list, key)
      list.find { |entity| entity.is_a?(Hash) && entity["key"] == key }
    end

    # Build a recursively-frozen copy of +node+. Hashes and arrays are rebuilt
    # with frozen children then frozen; strings are duped-and-frozen; immutable
    # scalars (Integer/Float/Symbol/true/false/nil) pass through unchanged. The
    # caller's original object graph is never mutated.
    def deep_freeze(node)
      case node
      when Hash
        result = {} #: Hash[untyped, untyped]
        node.each { |k, v| result[deep_freeze(k)] = deep_freeze(v) }
        result.freeze
      when Array
        node.map { |element| deep_freeze(element) }.freeze
      when String
        node.frozen? ? node : node.dup.freeze
      else
        node
      end
    end
  end
end
