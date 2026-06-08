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
module ConvertContext
  extend ActiveSupport::Concern

  private

  # The per-request Convert context, memoized for the duration of the request.
  # @return [ConvertSdk::Context]
  def convert_context
    @convert_context ||= CONVERT_SDK.create_context(convert_visitor_id, convert_visitor_attributes)
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
  # location + site-area pair (what a pricing experience typically gates on) plus
  # the platform environment. Override per call by merging into the run_* args.
  # @return [Hash{String=>String}]
  def convert_visitor_attributes
    {
      "country" => params[:country].presence || "US",
      "site_area" => params[:site_area].presence || "pricing",
      "environment" => ENV.fetch("CONVERT_ENVIRONMENT", "staging")
    }
  end
end
