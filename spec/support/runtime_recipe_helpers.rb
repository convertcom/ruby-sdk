# frozen_string_literal: true

require "open3"

# Shared scenario helpers for the Story 4.6 runtime-lifecycle recipe specs
# (spec/integration/runtime_recipes_spec.rb).
#
# Each runtime-matrix row (Puma cluster, Unicorn/Passenger, Sidekiq, AWS Lambda,
# plain CLI) is ONE described scenario that SIMULATES the runtime's lifecycle SHAPE
# using the SDK's real public machinery — never a real server gem. The common steps
# (build a factory client, bucket the known visitor, assert delivery) live here so
# the rows share them instead of copy-pasting (the SonarQube duplication guard and
# the architecture's no-copy-paste testing rule).
#
# Two delivery-evidence channels (reused from Story 4.4, never reinvented):
#   * IN-PROCESS rows (Sidekiq, Lambda) use WebMock capture (HttpStubs#capture).
#   * FORKED / SUBPROCESS rows (Puma, Unicorn/Passenger, CLI) cannot use WebMock
#     across the process boundary, so they use a {RecordingHttpClient} whose
#     request array is Marshalled back through {ForkHelpers#run_in_fork}'s pipe, or
#     a subprocess whose flush writes evidence to stdout (Open3).
#
# The recipe WIRING SNIPPET each scenario exercises is the exact code Story 5.3's
# quickstart will tell users to write — emitted as a co-located constant
# ({RECIPE_SNIPPETS}) so "no recipe is documentation-only" (AC#2 / NFR16) is
# mechanically checkable.
module RuntimeRecipeHelpers
  # The known-visitor bucketing facts (verified by Story 3.1 and the 4.6 gap test):
  # visitor-1 + these attributes buckets into experience 100218245 / variation
  # 100299457 of test-experience-ab-fullstack-2.
  RECIPE_VISITOR = "visitor-1"
  RECIPE_EXPERIENCE_KEY = "test-experience-ab-fullstack-2"
  RECIPE_EXPERIENCE_ID = "100218245"
  RECIPE_VARIATION_ID = "100299457"
  RECIPE_ACCOUNT_ID = "10022898"
  RECIPE_PROJECT_ID = "10025986"
  RECIPE_SDK_KEY = "sdk-key-1"

  # The attributes that make RECIPE_VISITOR eligible for the experience (the
  # transient audience match + the staging environment).
  RECIPE_ATTRIBUTES = {
    "varName1" => "value1", "varName2" => "value2", "environment" => "staging"
  }.freeze

  # The exact wiring snippet per recipe id — the copy-paste a Story 5.3 quickstart
  # ships. Co-located with the scenarios so the doc↔scenario traceability (AC#2) is
  # checkable: every documented recipe id MUST have an entry here AND a scenario.
  RECIPE_SNIPPETS = {
    "rails-puma-cluster" => <<~RUBY,
      # config/puma.rb — automatic fork detection needs NOTHING; the optional
      # belt-and-braces re-arm is one line in the worker-boot hook.
      preload_app!
      on_worker_boot { CONVERT_SDK.postfork }
    RUBY
    "unicorn-passenger-after-fork" => <<~RUBY,
      # config/unicorn.rb (Passenger: PhusionPassenger.on_event(:starting_worker_process))
      preload_app true
      after_fork { |_server, _worker| CONVERT_SDK.postfork }
    RUBY
    "sidekiq-shutdown-flush" => <<~RUBY,
      # config/initializers/sidekiq.rb
      Sidekiq.configure_server do |config|
        config.on(:shutdown) { CONVERT_SDK.flush }
      end
    RUBY
    "aws-lambda-sync-flush" => <<~RUBY,
      # handler.rb — timers OFF; flush synchronously before the handler returns.
      CONVERT_SDK = ConvertSdk.create(sdk_key: ENV["CONVERT_SDK_KEY"],
                                      data_refresh_interval: nil, flush_interval: nil)
      def handler(event:, context:)
        ctx = CONVERT_SDK.create_context(event["visitorId"])
        variation = ctx.run_experience("homepage-test")
        CONVERT_SDK.flush # MUST be synchronous — the env freezes after return
        { variation: variation.key }
      end
    RUBY
    "plain-cli-at-exit" => <<~RUBY
      # script.rb — the PID-guarded at_exit flush fires on normal exit.
      CONVERT_SDK = ConvertSdk.create(sdk_key: ENV["CONVERT_SDK_KEY"])
      ctx = CONVERT_SDK.create_context("cli-visitor")
      ctx.run_experience("homepage-test")
      # falls off the end -> at_exit flush delivers (NOT under SIGKILL)
    RUBY
  }.freeze

  # The vendored realistic config envelope (test-config.json) — the recipe clients
  # run direct-data so no config HTTP is needed.
  def recipe_config_data
    @recipe_config_data ||=
      JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__)))
  end

  # The WebMock track URL the recipe clients POST to (project-scoped, sdk-keyed).
  def recipe_track_url
    "#{HttpStubs::TRACK_HOST}/#{RECIPE_PROJECT_ID}/v1/track/#{RECIPE_SDK_KEY}"
  end

  # Stub the recipe track endpoint with request capture (the in-process rows'
  # delivery channel). Shared so the Sidekiq/Lambda rows don't repeat the stub.
  # @return [WebMock::RequestStub]
  def stub_recipe_track
    stub_request(:post, recipe_track_url).with(&capture)
                                         .to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
  end

  # Build a factory client wired for a recipe scenario: direct-data (no config
  # HTTP), pointed at the WebMock track host, with configurable timer intervals.
  # Timer-off by default (deterministic, thread-free); a row that needs the timer
  # passes an explicit interval.
  #
  # @param flush_interval [Numeric, nil] flush-timer seconds (nil = off).
  # @param data_refresh_interval [Numeric, nil] refresh-timer seconds (nil = off).
  # @return [ConvertSdk::Client]
  def build_recipe_client(flush_interval: nil, data_refresh_interval: nil)
    ConvertSdk.create(
      data: recipe_config_data,
      sdk_key: RECIPE_SDK_KEY,
      config_endpoint: HttpStubs::CONFIG_HOST,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      flush_interval: flush_interval,
      data_refresh_interval: data_refresh_interval
    )
  end

  # Replace a factory-built client's outbound HTTP port with a {RecordingHttpClient}
  # so delivery is assertable across a fork (the recorder's array Marshals back
  # through the run_in_fork pipe). Uses real machinery up to the HTTP port; only the
  # final socket write is faked. Returns the recorder.
  #
  # @param client [ConvertSdk::Client]
  # @return [ForkHelpers::RecordingHttpClient]
  def install_recording_http_client(client)
    recorder = ForkHelpers::RecordingHttpClient.new
    client.api_manager.instance_variable_set(:@http_client, recorder)
    recorder
  end

  # Bucket the known recipe visitor through a context and return the variation.
  # The single create-context-decide step the rows share (the recipe's "use").
  #
  # @param client [ConvertSdk::Client]
  # @param visitor_id [String]
  # @return [ConvertSdk::BucketedVariation, ConvertSdk::Sentinel]
  def recipe_bucket(client, visitor_id: RECIPE_VISITOR)
    client.create_context(visitor_id, RECIPE_ATTRIBUTES).run_experience(RECIPE_EXPERIENCE_KEY)
  end

  # The visitor ids carried by a recorded/captured track POST body, for an
  # order-independent delivery assertion shared across the forked rows.
  #
  # @param request_body [Hash, String] the POSTed body (Hash from RecordingHttpClient).
  # @return [Array<String>]
  def delivered_visitor_ids(request_body)
    body = request_body.is_a?(String) ? JSON.parse(request_body) : request_body
    Array(body["visitors"]).map { |entry| entry["visitorId"] }
  end

  # Block until +condition+ is truthy or +timeout+ elapses (bounded wait — no
  # sleep-and-hope). Polls on the monotonic clock. Returns the condition's last
  # value (truthy on success, falsey on timeout) so the caller can assert on it.
  #
  # @param timeout [Float] seconds to wait at most.
  # @param interval [Float] poll interval seconds.
  # @yieldreturn [Object] the condition, evaluated each poll.
  # @return [Object] the final condition value.
  def wait_until(timeout: 2.0, interval: 0.01)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    result = yield
    until result || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(interval)
      result = yield
    end
    result
  end
end

RSpec.configure do |config|
  config.include RuntimeRecipeHelpers
end
