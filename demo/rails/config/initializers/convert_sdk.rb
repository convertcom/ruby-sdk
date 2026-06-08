# frozen_string_literal: true

# =============================================================================
# THE documented Rails recipe — the initializer-singleton (teaching material).
# =============================================================================
#
# This is the canonical way to use the Convert SDK from Rails (Story 5.3's
# quickstart ships THIS file). Build ONE client at boot and reuse it for the life
# of the process. Under Puma cluster mode with `preload_app!`, this initializer
# runs ONCE in the master before any worker forks; every forked worker inherits
# the same client.
#
# ── THE FLAGSHIP CLAIM: ZERO FORK-HANDLING CODE ──────────────────────────────
# There is deliberately NO `postfork`, NO `on_worker_boot { CONVERT_SDK.postfork }`,
# NO fork hook anywhere in this demo. The SDK installs a `Process._fork` hook at
# require time (ConvertSdk::ForkGuard) that automatically re-arms the client in
# every forked child on its first use. The belt-and-braces explicit re-arm exists
# (and is documented in the quickstart), but it is NOT needed — and proving that
# is the entire point of this demo's fork-safety smoke test. Do not add fork code.
#
# The client is assigned to a top-level constant CONVERT_SDK so controllers (via
# the ConvertContext concern) reach it without a global lookup helper. A constant
# is the Rails-idiomatic singleton for a boot-time, never-reassigned object.
# -----------------------------------------------------------------------------

require "convert_sdk"

# Endpoint overrides (Story 2.4 config options): in the OFFLINE fork smoke these
# point at the local stub server; left unset they default to the live Convert
# endpoints (interactive `docker compose up` against the staging project).
convert_options = {
  sdk_key: ENV.fetch("CONVERT_SDK_KEY", "demo-sdk-key"),
  sdk_key_secret: ENV["CONVERT_SDK_KEY_SECRET"]
}

# Point config + track at the local stub when the smoke sets these (the SDK's
# config_endpoint / track_endpoint options make this a one-liner — no monkey
# patching, no test seam in lib code).
convert_options[:config_endpoint] = ENV["CONVERT_CONFIG_ENDPOINT"] if ENV["CONVERT_CONFIG_ENDPOINT"]
convert_options[:track_endpoint]  = ENV["CONVERT_TRACK_ENDPOINT"]  if ENV["CONVERT_TRACK_ENDPOINT"]

# In the offline smoke we keep the background refresh timer OFF (deterministic,
# thread-free) and rely on each demo request's explicit flush — set via ENV so
# the live mode keeps the default cadence.
convert_options[:data_refresh_interval] = nil if ENV["CONVERT_DEMO_TIMERS_OFF"] == "1"
convert_options[:flush_interval]        = nil if ENV["CONVERT_DEMO_TIMERS_OFF"] == "1"

# THE singleton. Built once in the preloading master; inherited by every worker.
CONVERT_SDK = ConvertSdk.create(**convert_options.compact)
