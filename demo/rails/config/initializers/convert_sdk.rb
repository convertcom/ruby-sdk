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
#
# ── TWO MODES, OFFLINE BY DEFAULT ────────────────────────────────────────────
# This demo runs in one of two clearly-separated modes, selected by the PRESENCE
# of credentials/endpoints — never a guess:
#
#   OFFLINE (default, zero credentials): when NEITHER `CONVERT_SDK_KEY` NOR
#     `CONVERT_CONFIG_ENDPOINT` is set, build the client in DIRECT-DATA mode
#     (`ConvertSdk.create(data: <committed config>)`). The config is a fixture
#     committed to config/convert_demo_config.json (a byte-copy of the SDK's
#     spec/fixtures/test-config.json, account 10022898). ZERO network requests —
#     deterministic, runnable with no setup. This is the plain `docker compose up`
#     / `puma -C config/puma.rb` case a human hits first.
#
#   LIVE / STUB (opt-in): when EITHER `CONVERT_SDK_KEY` OR `CONVERT_CONFIG_ENDPOINT`
#     is present, build via `ConvertSdk.create(sdk_key:, …)` with optional endpoint
#     overrides. This is the path the live shared-staging project uses AND the path
#     the release-blocking fork smoke (script/fork_smoke.rb) relies on — the smoke
#     sets BOTH `CONVERT_SDK_KEY=smoke-sdk-key` and `CONVERT_CONFIG_ENDPOINT`/
#     `CONVERT_TRACK_ENDPOINT` (pointed at its local stub). Because the OFFLINE
#     branch fires only when BOTH are ABSENT, the smoke keeps its sdk_key+stub path
#     untouched — that selector boundary is the contract this initializer must hold.
# -----------------------------------------------------------------------------

require "convert_sdk"
require "json"
require "logger"

# OFFLINE direct-data mode ⇔ NEITHER an SDK key NOR a config-endpoint override is
# present. (fork_smoke.rb sets both, so it never takes this branch.)
CONVERT_DEMO_OFFLINE = ENV["CONVERT_SDK_KEY"].to_s.strip.empty? &&
                       ENV["CONVERT_CONFIG_ENDPOINT"].to_s.strip.empty?

# Which entity keys the controller defaults to. This follows the CONFIG that is
# loaded, NOT the client-construction mode:
#   * OFFLINE direct-data mode loads the committed fixture (account 10022898).
#   * The fork smoke loads that SAME fixture, but via sdk_key + a CONFIG_ENDPOINT
#     override (its local stub serving spec/fixtures/test-config.json).
# In BOTH cases the controller must use the FIXTURE's entity keys. Only a genuine
# LIVE run — a real sdk_key with NO config-endpoint override (the live Convert
# config endpoint) — uses the shared-staging entity keys. So: LIVE keys ⇔ an
# sdk_key is set AND no config-endpoint override is present.
CONVERT_DEMO_LIVE_ENTITY_KEYS = !ENV["CONVERT_SDK_KEY"].to_s.strip.empty? &&
                                ENV["CONVERT_CONFIG_ENDPOINT"].to_s.strip.empty?

# Optional SDK log visibility (demo teaching aid). Set CONVERT_LOG_LEVEL=trace (or
# debug/info/…) to attach a stdlib Logger sink to the SDK at that {LogLevel}, so
# the decisioning internals (BucketingManager#…, ExperienceManager#…, DataManager#…,
# ApiManager#…) print to stdout. The redactor still masks any sdk_key. Left unset,
# the SDK is silent (no sink). NOT a lib change — just the public sink:/log_level:
# seams ConvertSdk.create already exposes.
convert_log_opts = {}
if (lvl = ENV["CONVERT_LOG_LEVEL"].to_s.strip.downcase).length.positive?
  level_const = { "trace" => ConvertSdk::LogLevel::TRACE, "debug" => ConvertSdk::LogLevel::DEBUG,
                  "info" => ConvertSdk::LogLevel::INFO, "warn" => ConvertSdk::LogLevel::WARN,
                  "error" => ConvertSdk::LogLevel::ERROR, "silent" => ConvertSdk::LogLevel::SILENT }[lvl]
  if level_const
    convert_log_opts[:log_level] = level_const
    convert_log_opts[:sink] = Logger.new($stdout)
  end
end

if CONVERT_DEMO_OFFLINE
  # Direct-data mode: hand the WHOLE parsed flat config to `create(data:)` —
  # no sdk_key, ZERO HTTP. Timers stay OFF so each /demo request flushes
  # synchronously and the decision is fully deterministic with no background
  # thread (NFR4). The committed fixture is already string-keyed JSON; parse and
  # pass through.
  demo_config = JSON.parse(File.read(Rails.root.join("config/convert_demo_config.json")))
  CONVERT_SDK = ConvertSdk.create(
    data: demo_config,
    data_refresh_interval: nil,
    flush_interval: nil,
    **convert_log_opts
  )
else
  # LIVE / STUB mode. Endpoint overrides (Story 2.4 config options): in the OFFLINE
  # fork smoke these point at the local stub server; in live mode they are left
  # unset and default to the live Convert endpoints (interactive run against the
  # shared staging project). The shared demo key 10035569/10034190 is a PUBLIC key
  # used with NO secret — mirroring the php-sdk/demo/laravel setup exactly. No
  # sdk_key_secret is wired here; the public key works without Bearer auth.
  convert_options = { sdk_key: ENV.fetch("CONVERT_SDK_KEY") }

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
  CONVERT_SDK = ConvertSdk.create(**convert_options.compact, **convert_log_opts)
end
