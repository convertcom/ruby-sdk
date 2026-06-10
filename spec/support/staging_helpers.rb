# frozen_string_literal: true

require "securerandom"

# Story 5.1 — shared scaffolding for the live-platform staging suite
# (+spec/staging/**+). Loaded globally by spec_helper like every other support
# file, but INERT until a staging example group opts into the shared context
# +"a live staging run"+ below — so it changes nothing for the default suite.
#
# Two responsibilities, both scoped to the staging context ONLY:
#
# 1. *Real-HTTP scoping.* The global lockdown (Story 1.1
#    +WebMock.disable_net_connect!+) stays in force everywhere. A staging
#    example needs the real platform, so the shared context lifts the lockdown
#    with +WebMock.allow_net_connect!+ around each example and RESTORES the
#    global lockdown afterwards — the relaxation never leaks into any other spec.
#
# 2. *ENV-gating.* Staging credentials come from two distinct env-var sets
#    (php-sdk-aligned two-key model, injected by staging.yml):
#    * WITHOUT-SECRET variant: +CONVERT_STAGING_SDK_KEY+ (a PUBLIC key, no Bearer).
#    * WITH-SECRET variant: +CONVERT_STAGING_SDK_KEY2+ + +CONVERT_STAGING_SDK_KEY2_SECRET+
#      (an AUTHENTICATED key + its matching secret, Bearer applied).
#    Credential selection is env-presence-driven; authenticated wins when both are
#    set (only reachable locally — CI injects exactly one variant's creds). A local
#    run without any staging vars must SKIP cleanly (never fail).
module StagingHelpers
  # Env var names for the two staging variants (php-sdk-aligned).
  PUBLIC_SDK_KEY_ENV        = "CONVERT_STAGING_SDK_KEY"
  AUTH_SDK_KEY_ENV          = "CONVERT_STAGING_SDK_KEY2"
  AUTH_SDK_KEY_SECRET_ENV   = "CONVERT_STAGING_SDK_KEY2_SECRET"

  # The message shown when a staging example is skipped for want of credentials.
  # Actionable: names all three vars grouped by variant, and how the suite runs.
  # A module function (not a constant) so the interpolated string needs no freeze dance.
  def self.skip_message
    "Set #{PUBLIC_SDK_KEY_ENV} (a PUBLIC staging key, no secret) for the " \
      "without-secret path, OR #{AUTH_SDK_KEY_ENV} + #{AUTH_SDK_KEY_SECRET_ENV} " \
      "(an AUTHENTICATED key + its secret) for the with-secret path, to run the " \
      "staging suite. It runs only on schedule/dispatch via " \
      ".github/workflows/staging.yml; the default `rake` excludes it (tagged :staging)."
  end

  # @return [Hash{Symbol=>String,nil}, nil] the variant-appropriate credentials,
  #   chosen by env presence (authenticated wins when both are set — only
  #   reachable locally; CI injects exactly one variant's creds), or nil when
  #   no staging credentials are configured (local runs skip cleanly).
  def staging_credentials
    key2   = present(AUTH_SDK_KEY_ENV)
    secret = present(AUTH_SDK_KEY_SECRET_ENV)
    return { sdk_key: key2, sdk_key_secret: secret } if key2 && secret

    public_key = present(PUBLIC_SDK_KEY_ENV)
    return { sdk_key: public_key, sdk_key_secret: nil } if public_key

    nil
  end

  # A unique visitor id per run — keeps scheduled staging runs clear of dedup
  # interference (the same visitor converting on the same goal twice is deduped;
  # a fresh id per run guarantees the tracked event is always a first conversion).
  # @return [String]
  def unique_staging_visitor_id
    "ruby-sdk-staging-#{Time.now.to_i}-#{SecureRandom.hex(6)}"
  end

  private

  # nil-or-blank-safe ENV read (a blank string is treated as absent).
  def present(name)
    value = ENV.fetch(name, nil)
    value if value && !value.strip.empty?
  end
end

RSpec.shared_context "a live staging run" do
  include StagingHelpers

  # Skip the whole group when no staging credentials are configured (local runs).
  # Done in a before hook (not at load) so the default suite — which excludes
  # :staging entirely — never even evaluates the gate, and a keyless
  # `--tag staging` local invocation skips with the actionable message rather
  # than erroring.
  before do
    skip(StagingHelpers.skip_message) unless staging_credentials
  end

  # Lift the global WebMock lockdown for the duration of each live example, then
  # RESTORE it — the relaxation is scoped strictly to the staging context. Net
  # connect is only ever allowed while a credentialed staging example runs.
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!(allow_localhost: false)
  end
end
