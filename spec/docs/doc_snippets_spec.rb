# frozen_string_literal: true

require "spec_helper"
require "logger"

# Story 5.3 (AC#6 / Task 6) — the docs-snippet smoke spec.
#
# Every code sample the docs ship (the README 5-minute start, the runtime
# quickstarts, the troubleshooting TRACE/Logger wiring) MUST run against the
# REAL gem, so documentation can never silently drift from the public API. This
# spec exercises the EXACT public flow the docs show — ConvertSdk.create ->
# create_context -> run_experience -> `case variation&.key` -> track_conversion
# -> flush — plus the documented sentinel contract, the timer-off (Lambda/CLI)
# wiring, and the stdlib-Logger sink wiring.
#
# It runs in the default suite (the `test` matrix job). It is deliberately thin:
# the runtime RECIPE wiring is already proven scenario-by-scenario in
# spec/integration/runtime_recipes_spec.rb (and cited from each quickstart via a
# "Tested by:" line) — this spec proves the README/troubleshooting prose samples
# specifically, reusing the shared helpers (no copy-pasted setup/fixtures, so it
# adds no coverage drag and no duplication).
RSpec.describe "Documentation code samples (Story 5.3)" do
  # Build the documented client in direct-data mode against the vendored fixture
  # so the samples run offline and deterministically (the README's fetch-mode
  # `sdk_key:` form is identical wiring — only the config source differs).
  def doc_client(**overrides)
    ConvertSdk.create(
      data: recipe_config_data, sdk_key: RuntimeRecipeHelpers::RECIPE_SDK_KEY,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1", **overrides
    )
  end

  before { stub_recipe_track }

  describe "README — the 5-minute start (the complete flow)" do
    it "create -> context -> run_experience -> case variation&.key -> track_conversion -> flush" do
      client = doc_client
      context = client.create_context(RuntimeRecipeHelpers::RECIPE_VISITOR,
                                      RuntimeRecipeHelpers::RECIPE_ATTRIBUTES)
      variation = context.run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY)

      # The documented branch pattern compiles and selects the hit branch.
      rendered =
        case variation&.key
        when nil then :default
        else          :variation
        end
      expect(rendered).to eq(:variation)

      # The documented revenue conversion + explicit flush deliver to the wire.
      context.track_conversion("purchase", goal_data: { amount: 49.99, transaction_id: "tx-1" })
      client.flush

      expect(captured_requests.size).to eq(1)
      expect(delivered_visitor_ids(captured_request.body)).to eq([RuntimeRecipeHelpers::RECIPE_VISITOR])
    end
  end

  describe "README — the sentinel return contract" do
    it "a miss returns a Sentinel: #key is nil and #error? is true (the case falls to else)" do
      variation = doc_client.create_context("visitor-1").run_experience("no-such-experience")

      expect(variation).to be_a(ConvertSdk::Sentinel)
      expect(variation.key).to be_nil
      expect(variation.error?).to be(true)
    end

    it "a hit returns a BucketedVariation: #error? is false" do
      variation = doc_client.create_context(RuntimeRecipeHelpers::RECIPE_VISITOR,
                                            RuntimeRecipeHelpers::RECIPE_ATTRIBUTES)
                            .run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY)

      expect(variation).to be_a(ConvertSdk::BucketedVariation)
      expect(variation.error?).to be(false)
    end
  end

  describe "quickstart-lambda — timer-off mode + synchronous flush (zero background threads)" do
    it "spawns no background thread and delivers on the synchronous flush" do
      baseline = Thread.list.size
      client = doc_client(data_refresh_interval: nil, flush_interval: nil)

      variation = client.create_context(RuntimeRecipeHelpers::RECIPE_VISITOR,
                                        RuntimeRecipeHelpers::RECIPE_ATTRIBUTES)
                        .run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY)
      client.flush # the documented "MUST be synchronous" handler-return flush

      expect(Thread.list.size - baseline).to eq(0)
      expect(variation).to be_a(ConvertSdk::BucketedVariation)
      expect(variation.id).to eq(RuntimeRecipeHelpers::RECIPE_VARIATION_ID)
      expect(captured_requests.size).to eq(1)
    end
  end

  describe "troubleshooting — stdlib Logger sink wiring at TRACE" do
    it "accepts a stdlib Logger as a sink and emits through it (no crash)" do
      io = StringIO.new
      logger = Logger.new(io)

      client = doc_client(log_level: ConvertSdk::LogLevel::TRACE, sink: logger)
      client.create_context(RuntimeRecipeHelpers::RECIPE_VISITOR,
                            RuntimeRecipeHelpers::RECIPE_ATTRIBUTES)
            .run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY)
      client.flush

      # The documented wiring produces log output (lifecycle/decision lines).
      expect(io.string).not_to be_empty
    end
  end
end
