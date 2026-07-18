# frozen_string_literal: true

# =============================================================================
# THE documented Rails recipe — the per-request Context concern (teaching material).
# =============================================================================
#
# Include this in any controller that decides experiences / features / segments
# or tracks conversions. It builds ONE Convert `Context` per request, bound to
# the request's visitor identity, from the singleton CONVERT_SDK client.
#
# A `Context` is the per-visitor decisioning surface: it carries the visitor id
# and attributes and exposes run_experience / run_feature / run_custom_segments /
# track_conversion. It is cheap to create per request (no network, no thread) —
# the singleton client owns all the shared state.
#
# Visitor identity for the demo: a `visitor_id` query param or the
# `X-Convert-Visitor-Id` header. A real app would read a first-party cookie. The
# fork smoke supplies `visitor_id=smoke-test-{pid}-{n}` so the stub can attribute
# each tracked event to the worker PID that produced it.
#
# NOTE: ZERO fork-handling code here either — see config/initializers/convert_sdk.rb.
#
# ── qs-08 preview links (`?convert_preview={experienceId}.{variationId}`) ────
# The demo's second documented recipe: parse the canonical preview link param
# off THIS request and, when present, force the context's `run_experience` for
# that one experience to the given variation — bypassing bucketing/audiences/
# status/environment/stored-decisions and suppressing ALL tracking + visitor-
# state persistence for the rest of this context's lifetime (SDK-level
# zero-trace guarantee, `Context#set_preview`). Inert (no-op) on a missing or
# malformed param — `ConvertSdk.parse_preview_param` returns `nil` and we simply
# skip `set_preview`.
module ConvertContext
  extend ActiveSupport::Concern

  private

  # The per-request Convert context, memoized for the duration of the request.
  # Preview resolution (if any) happens exactly once, at build time, so every
  # later `convert_context` call in the request sees the same forced state.
  # @return [ConvertSdk::Context]
  def convert_context
    @convert_context ||= begin
      context = CONVERT_SDK.create_context(convert_visitor_id, convert_visitor_attributes)
      @convert_preview_pair = context ? apply_convert_preview(context) : nil
      context
    end
  end

  # Whether `?convert_preview=` resolved to a forced variation on THIS request's
  # context. `@convert_preview_pair` is only ever nil (inactive) or a 2-element
  # array (active) — never boolean false — so a plain `defined?`-free nil check
  # is safe here (no `||=`-on-false footgun).
  # @return [Boolean]
  def convert_preview_active?
    convert_context # ensure preview resolution has run
    !@convert_preview_pair.nil?
  end

  # The forced experience id for this request, or nil when preview is inactive.
  # @return [String, nil]
  def convert_preview_experience_id
    convert_context
    @convert_preview_pair&.first
  end

  # The forced variation id for this request, or nil when preview is inactive.
  # @return [String, nil]
  def convert_preview_variation_id
    convert_context
    @convert_preview_pair&.last
  end

  # Parse `params[:convert_preview]` and, when it is a valid
  # `"{experienceId}.{variationId}"` pair, force it on +context+ via
  # `Context#set_preview` and log the same observable line the php-sdk demo
  # emits (the "watch the logs" verification step in the README).
  # @param context [ConvertSdk::Context]
  # @return [Array(String, String), nil] the parsed pair, or nil when inactive
  def apply_convert_preview(context)
    pair = ConvertSdk.parse_preview_param(params[:convert_preview])
    return nil if pair.nil?

    experience_id, variation_id = pair
    context.set_preview(experience_id: experience_id, variation_id: variation_id)
    Rails.logger.info(
      "[ConvertSDK] Preview active — experience_id=#{experience_id} " \
      "variation_id=#{variation_id} (zero-trace context)"
    )
    pair
  end

  # The demo's visitor identity: explicit param/header, else a per-request
  # anonymous id. Real apps read a first-party cookie here.
  # @return [String]
  def convert_visitor_id
    params[:visitor_id].presence ||
      request.headers["X-Convert-Visitor-Id"].presence ||
      "anon-#{SecureRandom.hex(8)}"
  end

  # Visitor attributes drive audience/segment matching. The demo passes a
  # location + site-area pair (what a pricing experience typically gates on), the
  # platform environment, AND the two audience keys the OFFLINE fixture's
  # experience audience gates on (`varName1`/`varName2`) — without those, the
  # offline experience's audience does not match and the SDK correctly returns a
  # NO_DATA_FOUND miss (verified against the committed config_data audience
  # 100299433; the full-chain release gate pins the same matching set). Every value
  # is overridable per request via a query param so a human can experiment.
  # @return [Hash{String=>String}]
  def convert_visitor_attributes
    {
      "varName1" => params[:varName1].presence || "value1",
      "varName2" => params[:varName2].presence || "value2",
      "country" => params[:country].presence || "US",
      "site_area" => params[:site_area].presence || "pricing",
      "environment" => params[:environment].presence ||
        ENV.fetch("CONVERT_ENVIRONMENT", "staging")
    }
  end
end
