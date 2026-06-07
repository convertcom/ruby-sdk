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
    def initialize(visitor_id:, data_manager:, data_store_manager:, event_manager:,
                   log_manager:, config:, attributes: nil)
      @visitor_id = visitor_id
      @data_manager = data_manager
      @data_store_manager = data_store_manager
      @event_manager = event_manager
      @log_manager = log_manager
      @config = config
      # Deep-stringify the caller's attributes ONCE at the boundary; internals
      # only ever see string keys. nil → empty. The caller's hash is never mutated.
      @attributes = deep_stringify(attributes || {})
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
    # @param properties [Hash] the properties to merge (symbol or string keys).
    # @return [self]
    def update_visitor_properties(properties)
      normalised = deep_stringify(properties || {})
      @data_store_manager.merge_visitor_data(account_key, project_key, @visitor_id) do |_current|
        { "segments" => normalised }
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
    # (a string or symbol; case-insensitive) — and dispatches to the matching
    # {DataManager} by-key reader. A miss (unknown key OR unknown type) returns
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

    private

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
