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
# 2. *ENV-gating.* The staging credentials come from the +CONVERT_SDK_KEY+ /
#    +CONVERT_SDK_KEY_SECRET+ repository secrets, surfaced as env vars by
#    staging.yml. A local run without them must SKIP cleanly (never fail): the
#    shared context skips every example with an actionable message when the key
#    is absent.
module StagingHelpers
  # The env var names carrying the staging credentials (staging.yml maps the
  # repository secrets onto these). The secret is optional — the staging project
  # supports a with-secret and a without-secret variant — so only the KEY gates.
  SDK_KEY_ENV = "CONVERT_SDK_KEY"
  SDK_KEY_SECRET_ENV = "CONVERT_SDK_KEY_SECRET"

  # The message shown when a staging example is skipped for want of credentials.
  # Actionable: it names the env var and how the suite is meant to run. A module
  # function (not a constant) so the interpolated string needs no freeze dance.
  def self.skip_message
    "Set #{SDK_KEY_ENV} (a live staging SDK key) to run the staging suite. " \
      "It runs only on schedule/dispatch via .github/workflows/staging.yml; " \
      "the default `rake` excludes it (tagged :staging)."
  end

  # @return [String, nil] the live staging SDK key from the environment, or nil.
  def staging_sdk_key
    value = ENV.fetch(SDK_KEY_ENV, nil)
    value if value && !value.strip.empty?
  end

  # @return [String, nil] the optional staging SDK key secret from the
  #   environment (the with-secret variant), or nil when unset.
  def staging_sdk_key_secret
    value = ENV.fetch(SDK_KEY_SECRET_ENV, nil)
    value if value && !value.strip.empty?
  end

  # A unique visitor id per run — keeps scheduled staging runs clear of dedup
  # interference (the same visitor converting on the same goal twice is deduped;
  # a fresh id per run guarantees the tracked event is always a first conversion).
  # @return [String]
  def unique_staging_visitor_id
    "ruby-sdk-staging-#{Time.now.to_i}-#{SecureRandom.hex(6)}"
  end
end

RSpec.shared_context "a live staging run" do
  include StagingHelpers

  # Skip the whole group when no live key is configured (local runs). Done in a
  # before hook (not at load) so the default suite — which excludes :staging
  # entirely — never even evaluates the gate, and a keyless `--tag staging`
  # local invocation skips with the actionable message rather than erroring.
  before do
    skip(StagingHelpers.skip_message) unless staging_sdk_key
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
