# frozen_string_literal: true

# =============================================================================
# The full-loop demo controller (teaching material).
# =============================================================================
#
# Exercises the ENTIRE public SDK surface through the documented recipe — nothing
# here reaches past the public API:
#
#   * run_experience      — pricing experience gated on location/site-area props
#   * run_feature         — feature flag with typed variables rendered
#   * run_custom_segments — report-segment evaluation
#   * track_conversion    — revenue conversion (a purchase) with goal_data
#   * flush               — explicit synchronous delivery
#
# ── Rendering: HTML by default, JSON on demand ───────────────────────────────
# The app boots api_only (config.api_only = true in application.rb), so the
# DEFAULT controller base (ActionController::API) cannot render views. This single
# controller needs BOTH a bare HTML view AND the existing JSON shape, so it
# inherits ActionController::Base — the one base with a complete, correctly-ordered
# rendering stack (view rendering + the JSON renderer + content negotiation).
#
# A narrower hand-rolled include set onto ActionController::API was tried and
# REJECTED: mixing ActionView::Rendering + ImplicitRender onto the API base broke
# `render json:` (it fell through to an ImplicitRender template lookup → 500
# MissingTemplate on /pid and the JSON branch). ActionController::Base is the
# documented, supported base for a view+JSON controller; using it for this ONE
# controller leaves the rest of the app api_only. Forgery protection is skipped
# (api_only strips the session/cookie middleware CSRF needs, and /flush is a
# trivial demo POST with nothing to protect).
#
# ── Entity keys: mode-aware defaults ─────────────────────────────────────────
# OFFLINE (the default, direct-data) buckets against the committed fixture
# (account 10022898), so the defaults are that fixture's real keys. LIVE (opt-in,
# shared staging project 10035569/10034190) defaults to the php-sdk demo's
# verified keys. The mode is decided once at boot (CONVERT_DEMO_OFFLINE, set by
# config/initializers/convert_sdk.rb); an empty .env "just works" in either mode.
class DemoController < ActionController::Base
  skip_forgery_protection

  include ConvertContext

  # GET /pid — the worker-identity endpoint the fork smoke polls to discover which
  # Ruby process (Puma worker) is serving requests. The smoke embeds this PID in
  # the visitor id so the stub can prove BOTH forked workers delivered events.
  def pid
    render json: { pid: Process.pid }
  end

  # GET /demo — run the full loop for this request's visitor and return what the
  # SDK decided. Drives every public decisioning + tracking method, then renders
  # an observable summary: HTML for a human (default), JSON for curl/CI.
  def run
    variation = convert_context.run_experience(pricing_experience_key)
    feature   = convert_context.run_feature(feature_key)
    # The offline fixture's segment (test-segments-1) matches on `enabled == true`
    # (rule key "enabled"). Segment rule data is read from the `ruleData` key of the
    # per-call attributes (Context#visitor_properties → attributes[:ruleData]);
    # passing it as `ruleData:` is what makes the segment attach (verified against
    # the committed config_data segment 200299434, mirroring the full-chain gate's
    # run_custom_segments([segment_key], { ruleData: { "enabled" => true } })).
    convert_context.run_custom_segments([segment_key], { ruleData: { "enabled" => true } })
    transaction_id = "tx-#{SecureRandom.hex(6)}"
    convert_context.track_conversion(
      goal_key,
      goal_data: { amount: purchase_amount, transaction_id: transaction_id }
    )

    # In timer-off mode (the offline default + the offline smoke) deliver
    # synchronously so the decision/conversion are observable within the request;
    # in live timer-on mode the background timer also drains.
    CONVERT_SDK.flush("demo-request") if timers_off?

    @summary = build_summary(variation, feature, transaction_id)

    respond_to do |format|
      format.html # renders app/views/demo/run.html.erb
      format.json { render json: @summary }
    end
  end

  # POST /flush — explicit synchronous flush surface (humans / CI force delivery).
  def flush
    CONVERT_SDK.flush("manual")
    render json: { flushed: true, pid: Process.pid }
  end

  private

  # Build the plain "what the SDK did" summary consumed by BOTH the JSON response
  # and the HTML view, so the two formats render identical data.
  def build_summary(variation, feature, transaction_id)
    {
      mode: CONVERT_DEMO_OFFLINE ? "offline" : "live",
      pid: Process.pid,
      visitor_id: convert_visitor_id,
      attributes: convert_visitor_attributes,
      experience: variation_summary(variation),
      feature: feature_summary(feature),
      segments: attached_segments,
      conversion: {
        goal_key: goal_key,
        amount: purchase_amount,
        transaction_id: transaction_id
      }
    }
  end

  # ── Entity keys (mode-aware ENV-overridable defaults) ──────────────────────
  # OFFLINE defaults are the committed fixture's real keys (account 10022898), so
  # the offline demo buckets deterministically without any credentials. LIVE
  # defaults are the php-sdk demo's verified shared-staging keys.

  def pricing_experience_key
    ENV.fetch("CONVERT_PRICING_EXPERIENCE_KEY", entity_default(:experience))
  end

  def feature_key
    ENV.fetch("CONVERT_FEATURE_KEY", entity_default(:feature))
  end

  def segment_key
    ENV.fetch("CONVERT_SEGMENT_KEY", entity_default(:segment))
  end

  def goal_key
    ENV.fetch("CONVERT_GOAL_KEY", entity_default(:goal))
  end

  # The per-mode default entity key. The fixture's keys are the default for BOTH
  # OFFLINE direct-data AND the fork smoke (which serves that same fixture via a
  # config-endpoint override); only a genuine LIVE staging run uses the
  # shared-staging keys. The boot-time CONVERT_DEMO_LIVE_ENTITY_KEYS flag (set in
  # config/initializers/convert_sdk.rb) encodes exactly that distinction.
  def entity_default(kind)
    table = CONVERT_DEMO_LIVE_ENTITY_KEYS ? LIVE_ENTITY_KEYS : OFFLINE_ENTITY_KEYS
    table.fetch(kind)
  end

  # The committed offline fixture's real keys (account 10022898).
  OFFLINE_ENTITY_KEYS = {
    experience: "test-experience-ab-fullstack-2",
    feature: "feature-1",
    segment: "test-segments-1",
    goal: "goal-without-rule"
  }.freeze

  # The shared live-staging project's keys (10035569/10034190), matching the
  # php-sdk demo's verified entities.
  LIVE_ENTITY_KEYS = {
    experience: "test-experience-ab-fullstack-1",
    feature: "feature-5",
    segment: "test-segment-1",
    goal: "button-primary-click"
  }.freeze

  def purchase_amount
    Float(ENV.fetch("CONVERT_DEMO_PURCHASE_AMOUNT", "49.99"))
  end

  def timers_off?
    CONVERT_DEMO_OFFLINE || ENV["CONVERT_DEMO_TIMERS_OFF"] == "1"
  end

  # The custom-segment ids attached to this visitor after run_custom_segments —
  # read back from the visitor's persisted StoreData. The SDK stores matched
  # custom segments under segments["customSegments"] as an array of segment ids
  # (verified: get_visitor_data["segments"] == {"customSegments" => ["200299434"]}).
  # @return [Array<String>]
  def attached_segments
    data = convert_context.get_visitor_data
    seg = data.is_a?(Hash) ? data["segments"] : nil
    custom = seg.is_a?(Hash) ? seg["customSegments"] : nil
    custom.is_a?(Array) ? custom : []
  end

  # Render a typed-variable feature summary: a hit exposes its cast variables (each
  # with its Ruby cast class so the view can show the type); a miss / disabled
  # feature is reported as such (never an exception — the SDK degrades to a
  # DISABLED BucketedFeature).
  def feature_summary(feature)
    Array(feature).map do |bf|
      vars = bf.respond_to?(:variables) && bf.variables.is_a?(Hash) ? bf.variables : {}
      {
        key: bf.respond_to?(:key) ? bf.key : nil,
        status: bf.respond_to?(:status) ? bf.status : nil,
        variables: vars.transform_values { |v| { value: v, type: v.class.name } }
      }
    end
  end

  # Render an experience summary: a BucketedVariation exposes its ids/key; a miss
  # is an error sentinel (reported as a miss, never raised).
  def variation_summary(variation)
    if variation.is_a?(ConvertSdk::BucketedVariation)
      { bucketed: true, experience_id: variation.experience_id,
        variation_id: variation.id, variation_key: variation.key }
    else
      { bucketed: false, reason: variation.to_s }
    end
  end
end
