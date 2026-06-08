# frozen_string_literal: true

require "spec_helper"

# Story 4.6 (gap-closer) — the end-to-end proof that a REAL factory-built client
# can decide and deliver. Before this story the factory wired the ApiManager into
# the Context but NOT the decisioning managers (BucketingManager / RuleManager into
# the DataManager flow; ExperienceManager / FeatureManager / SegmentsManager into
# the Context), so `ConvertSdk.create(...).create_context(vid).run_experience(key)`
# returned a NO_DATA_FOUND sentinel and enqueued nothing. This spec pins the
# closed gap: a real client buckets the known visitor into a real variation,
# enqueues the bucketing event, and `flush` POSTs the golden wire payload.
#
# The bucketing facts are the SAME ones the hand-wired flush_wiring_spec proves:
# visitor-1 + {varName1,varName2,environment:staging} buckets into experience
# 100218245 / variation 100299457 of test-experience-ab-fullstack-2.
RSpec.describe "Factory decisioning wiring (Story 4.6 gap-closer)" do
  let(:config_data) do
    JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__)))
  end

  # The known-good attributes that make visitor-1 eligible for fullstack-2 (the
  # transient audience + the staging environment; no location_properties means the
  # site_area gate is unrestricted — DataManager#match_locations returns true).
  let(:matching) do
    { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" }
  end

  let(:exp_key) { "test-experience-ab-fullstack-2" }

  # A factory client in direct-data mode (no config HTTP), timer-off (no flush /
  # refresh threads — deterministic), pointed at the WebMock track host so the
  # golden payload can be captured on an explicit flush.
  def build_client
    ConvertSdk.create(
      data: config_data,
      sdk_key: "sdk-key-1",
      config_endpoint: HttpStubs::CONFIG_HOST,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      flush_interval: nil,
      data_refresh_interval: nil
    )
  end

  it "buckets visitor-1 into a real frozen variation (NOT a sentinel)" do
    variation = build_client.create_context("visitor-1", matching).run_experience(exp_key)

    expect(variation).to be_a(ConvertSdk::BucketedVariation)
    expect(variation).to be_frozen
    expect(variation.experience_id).to eq("100218245")
    expect(variation.id).to eq("100299457")
  end

  it "enqueues a bucketing event for the decided variation" do
    client = build_client
    client.create_context("visitor-1", matching).run_experience(exp_key)

    expect(client.api_manager.queue.size).to eq(1)
  end

  it "flush POSTs the golden wire payload to the track endpoint" do
    client = build_client
    stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
      .with(&capture).to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)

    client.create_context("visitor-1", matching).run_experience(exp_key)
    client.flush("test")

    body = captured_request.body
    parsed = body.is_a?(String) ? JSON.parse(body) : body
    expect(parsed).to eq(
      expected_track_payload(
        account_id: "10022898",
        project_id: "10025986",
        visitors: [
          {
            "visitorId" => "visitor-1",
            "events" => [
              {
                "eventType" => "bucketing",
                "data" => { "experienceId" => "100218245", "variationId" => "100299457" }
              }
            ]
          }
        ]
      )
    )
  end

  it "starts no background threads in the factory (NFR4 — lazy/timer-off)" do
    baseline = Thread.list.size
    client = build_client
    delta = Thread.list.size - baseline

    expect(client).to be_a(ConvertSdk::Client)
    expect(delta).to eq(0)
  end
end
