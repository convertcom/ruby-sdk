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
# Entity keys come from ENV (see .env.example). In the OFFLINE fork smoke they
# default to the canned config's keys so the demo buckets deterministically
# against the local stub; in live mode they are the staging project's real keys.
class DemoController < ActionController::API
  include ConvertContext

  # GET /pid — the worker-identity endpoint the fork smoke polls to discover which
  # Ruby process (Puma worker) is serving requests. The smoke embeds this PID in
  # the visitor id so the stub can prove BOTH forked workers delivered events.
  def pid
    render json: { pid: Process.pid }
  end

  # GET /demo — run the full loop for this request's visitor and return a summary
  # of what the SDK decided. Drives every public decisioning + tracking method.
  def run
    variation = convert_context.run_experience(pricing_experience_key)
    feature   = convert_context.run_feature(feature_key)
    convert_context.run_custom_segments([segment_key])
    convert_context.track_conversion(
      goal_key,
      goal_data: { amount: purchase_amount, transaction_id: "tx-#{SecureRandom.hex(6)}" }
    )

    # In timer-off mode (the offline smoke) deliver synchronously so the stub sees
    # the events within the request; in live mode the background timer also drains.
    CONVERT_SDK.flush("demo-request") if ENV["CONVERT_DEMO_TIMERS_OFF"] == "1"

    render json: {
      pid: Process.pid,
      visitor_id: convert_visitor_id,
      experience: variation_summary(variation),
      feature: feature_summary(feature)
    }
  end

  # POST /flush — explicit synchronous flush surface (humans / CI force delivery).
  def flush
    CONVERT_SDK.flush("manual")
    render json: { flushed: true, pid: Process.pid }
  end

  private

  # ── Entity keys (ENV with canned-config offline defaults) ──────────────────
  # The defaults are the keys present in the SDK's vendored test-config.json, so
  # the offline smoke buckets deterministically without real staging keys.

  def pricing_experience_key
    ENV.fetch("CONVERT_PRICING_EXPERIENCE_KEY", "test-experience-ab-fullstack-2")
  end

  def feature_key
    ENV.fetch("CONVERT_FEATURE_KEY", "feature-1")
  end

  def segment_key
    ENV.fetch("CONVERT_SEGMENT_KEY", "test-segments-1")
  end

  def goal_key
    ENV.fetch("CONVERT_GOAL_KEY", "goal-without-rule")
  end

  def purchase_amount
    Float(ENV.fetch("CONVERT_DEMO_PURCHASE_AMOUNT", "49.99"))
  end

  # Render a typed-variable feature summary: a hit exposes its cast variables; a
  # miss / disabled feature is reported as such (never an exception — the SDK
  # degrades to a DISABLED BucketedFeature).
  def feature_summary(feature)
    Array(feature).map do |bf|
      {
        key: bf.key,
        status: bf.status,
        variables: bf.respond_to?(:variables) ? bf.variables : {}
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
