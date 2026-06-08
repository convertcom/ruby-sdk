# frozen_string_literal: true

require "spec_helper"

# Story 5.1 AC#3 — live end-to-end tracking gate (FR65).
#
# A scheduled run drives the FULL public loop against the shared staging project
# — create -> create_context -> run_experience -> track_conversion (with revenue
# goal_data) -> flush — and asserts the tracked events were ACCEPTED by the live
# tracking endpoint.
#
# == The delivery-acceptance observable (F-027)
#
# +Client#flush+ returns +self+ — no delivery receipt is surfaced to the caller
# (Story 4.1: drain-and-swap, no return value). So acceptance is observed two
# ways, both through the public surface:
#
#   1. the +api.queue.released+ lifecycle event (Story 4.2) fires ONLY on a 2xx
#      delivery (ApiManager#deliver fires it inside the success branch), and
#   2. NO delivery-failure +warn+ line is emitted (ApiManager logs
#      "delivery failed, retaining … (status N)" on a non-2xx and does NOT fire
#      the event).
#
# A 4xx/5xx from the live endpoint therefore FAILS this spec loudly: the event
# never fires (assertion 1 fails) and the failure warn appears (assertion 2
# fails). There are NO bounded retries — a failing live endpoint SHOULD fail the
# scheduled job; that failure IS the drift alarm.
#
# == Clean staging data
#
# A UNIQUE visitor id per run keeps scheduled runs free of dedup interference (a
# repeat visitor converting on the same goal would be deduped, so the conversion
# event would silently not enqueue). A fresh id guarantees a first conversion.
#
# Tagged :staging; skips cleanly without CONVERT_SDK_KEY; real-HTTP scoped here.

# The substring ApiManager logs on a NON-2xx delivery (the loud-failure signal).
# Module-namespaced (not in-block) so RuboCop's Lint/ConstantDefinitionInBlock
# stays happy — the full_chain_spec precedent.
module StagingTrackingSignals
  DELIVERY_FAILED = "delivery failed"
end

RSpec.describe "Live end-to-end tracking (Story 5.1 AC#3)", :staging do
  include_context "a live staging run"

  # A CapturingSink wired at create so EVERY log line — including the
  # ApiManager delivery success/failure lines — is observable. The delivery-
  # failure warn substring is the loud-failure signal (assertion 2).
  let(:sink) { CapturingSink.new }

  # Live fetch-mode client, timer-off (no background thread), sink attached so
  # the delivery outcome is observable. Secret variant attached when present.
  # Run at TRACE (the finest level) so the FULL lifecycle — including the
  # init-time config GET whose URL carries the raw sdk_key — is captured, making
  # the zero-leakage scan (AC#4) a real proof that the Redactor ran live, not
  # that the secret merely never appeared.
  let(:client) do
    opts = {
      sdk_key: staging_sdk_key, data_refresh_interval: nil,
      sink: sink, log_level: ConvertSdk::LogLevel::TRACE
    }
    secret = staging_sdk_key_secret
    opts[:sdk_key_secret] = secret if secret
    ConvertSdk.create(**opts)
  end

  let(:dm) { client.data_manager }

  # The first experience/goal keys from the LIVE config — the loop drives REAL
  # entities (no hardcoded keys; staging content can change, but a populated
  # project always has at least one of each).
  def first_experience_key
    dm.experiences.filter_map { |e| e["key"] }.first
  end

  def first_goal_key
    dm.goals.filter_map { |g| g["key"] }.first
  end

  # Subscribe to api.queue.released and run the full loop; returns whether the
  # release event fired. The single ordered scenario, reused by both assertions.
  def run_loop_and_capture_release
    released = []
    client.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |payload, _err| released << payload }

    context = client.create_context(unique_staging_visitor_id)
    exp_key = first_experience_key
    goal_key = first_goal_key
    context.run_experience(exp_key) if exp_key
    context.track_conversion(goal_key, goal_data: revenue_goal_data) if goal_key
    client.flush("staging-e2e")

    released
  end

  # The revenue/transaction goal_data for the live conversion (snake_case keys
  # of the platform GoalDataKey set). Extracted so the loop line stays readable.
  def revenue_goal_data
    { amount: 19.99, transaction_id: "ruby-sdk-staging-tx" }
  end

  it "fetches a populated config with at least one experience and goal to drive" do
    expect(first_experience_key).not_to be_nil, "staging project has no experiences to run"
    expect(first_goal_key).not_to be_nil, "staging project has no goals to convert on"
  end

  it "delivers the tracked events — api.queue.released fires and NO failure is logged" do
    released = run_loop_and_capture_release

    # Acceptance signal 1: the release event fired (ApiManager fires it ONLY on a
    # 2xx delivery). A non-empty queue that 2xx-delivers fires exactly once.
    expect(released).not_to be_empty,
                            "api.queue.released never fired — the live endpoint did not accept the events"
    expect(released.first["reason"]).to eq("staging-e2e")
    expect(released.first["visitors"]).to be >= 1

    # Acceptance signal 2: no delivery-failure warn anywhere (a 4xx/5xx logs it).
    expect(sink.joined).not_to include(StagingTrackingSignals::DELIVERY_FAILED),
                               "the live endpoint rejected the delivery: #{sink.joined}"
  end

  # AC#4 — zero-leakage under LIVE conditions (NFR5). The whole loop already runs
  # at TRACE with the CapturingSink attached at create, so the captured log spans
  # the FULL lifecycle (init config GET → decision → track → flush). Proves the
  # Redactor masked the live secret across every line — the 4.7 scan pattern, now
  # against the real platform. Skips with the rest of the group without keys; the
  # with-secret CI variant is where the secret-leakage assertion is meaningful.
  it "never leaks the raw sdk_key / sdk_key_secret across the TRACE lifecycle (NFR5)" do
    run_loop_and_capture_release
    log = sink.joined

    # We observed the full lifecycle (the init-time config GET line is present).
    expect(log).to include("HttpClient#request: GET")

    # Zero raw secrets anywhere — the load-bearing NFR5 assertion under live runs.
    expect(log).not_to include(staging_sdk_key)
    secret = staging_sdk_key_secret
    expect(log).not_to include(secret) if secret

    # And the Redactor demonstrably RAN: the masked sdk_key form (first-4 + "…")
    # appears on the line that carried it (the config URL), proving redaction
    # rather than coincidental absence.
    masked_key = "#{staging_sdk_key[0, 4]}…"
    expect(log).to include(masked_key)
  end
end
