# frozen_string_literal: true

require "spec_helper"

# Story 4.6 — Runtime lifecycle recipes (FR46 / NFR16). One described scenario per
# frozen runtime-matrix row, each named with a STABLE recipe id (the Story 5.3
# quickstart references the scenario 1:1; the co-located {RuntimeRecipeHelpers::
# RECIPE_SNIPPETS} entry is the exact wiring code the doc ships). Scenarios exercise
# the runtime's lifecycle HOOK SHAPE using the SDK's real public machinery — no
# puma/unicorn/sidekiq gem dependency. Fork rows are CRuby-only (run_in_fork);
# non-fork rows (Sidekiq, Lambda, CLI-without-fork) run everywhere incl. JRuby.
#
# Delivery evidence: in-process rows use WebMock capture; forked / subprocess rows
# use the Story 4.4 RecordingHttpClient (Marshalled back through the fork pipe) or
# an Open3 subprocess whose flush writes stdout evidence.
RSpec.describe "Runtime lifecycle recipes (Story 4.6)" do
  before { reset_fork_guard! }
  after { reset_fork_guard! }

  # AC#2 / NFR16 — the mechanical doc↔scenario traceability check: every recipe id
  # this suite documents has BOTH a wiring snippet (what the quickstart ships) and a
  # described scenario below. No recipe is documentation-only.
  describe "recipe↔doc traceability (AC#2)" do
    it "has a wiring snippet for every documented recipe id" do
      expect(RuntimeRecipeHelpers::RECIPE_SNIPPETS.keys).to contain_exactly(
        "rails-puma-cluster", "unicorn-passenger-after-fork",
        "sidekiq-shutdown-flush", "aws-lambda-sync-flush", "plain-cli-at-exit"
      )
      RuntimeRecipeHelpers::RECIPE_SNIPPETS.each_value do |snippet|
        expect(snippet).to include("CONVERT_SDK")
      end
    end
  end

  describe "recipe: rails-puma-cluster", :fork do
    before { skip_unless_fork_supported }

    # The default Rails deployment: client built in the preloading master (no use),
    # then a worker forks. The Process._fork hook (4.4) re-arms automatically — the
    # forked worker decides and delivers with ZERO configuration.
    it "(automatic) preload-shape parent forks -> worker buckets + delivers, no hook" do
      ConvertSdk::ForkGuard.install!
      client = build_recipe_client # parent builds, never uses (preload shape)

      delivered = run_in_fork do
        recorder = install_recording_http_client(client)
        variation = recipe_bucket(client) # worker's first use re-arms lazily
        client.flush("worker")
        { variation_id: variation.is_a?(ConvertSdk::BucketedVariation) ? variation.id : nil,
          requests: recorder.requests }
      end

      expect(delivered[:variation_id]).to eq(RuntimeRecipeHelpers::RECIPE_VARIATION_ID)
      expect(delivered[:requests].size).to eq(1)
      expect(delivered_visitor_ids(delivered[:requests].first[:body]))
        .to eq([RuntimeRecipeHelpers::RECIPE_VISITOR])
    end

    # The belt-and-braces recipe: an explicit on_worker_boot { client.postfork } in
    # the worker-boot position (the snippet ships this). postfork re-arms; the
    # worker then buckets + delivers identically.
    it "(belt-and-braces) on_worker_boot { postfork } -> worker buckets + delivers" do
      ConvertSdk::ForkGuard.install!
      client = build_recipe_client

      delivered = run_in_fork do
        client.postfork # the on_worker_boot hook body
        recorder = install_recording_http_client(client)
        recipe_bucket(client)
        client.flush("worker")
        recorder.requests
      end

      expect(delivered.size).to eq(1)
      expect(delivered_visitor_ids(delivered.first[:body])).to eq([RuntimeRecipeHelpers::RECIPE_VISITOR])
    end
  end

  describe "recipe: unicorn-passenger-after-fork", :fork do
    before { skip_unless_fork_supported }

    # Unicorn after_fork (and the identical-shape Passenger
    # on_event(:starting_worker_process)) call client.postfork in the forked child;
    # the child then buckets and delivers. One scenario covers both — the hook
    # bodies are identical (documented in RECIPE_SNIPPETS).
    it "after_fork-position hook calls postfork -> child buckets + delivers (covers Passenger)" do
      ConvertSdk::ForkGuard.install!
      client = build_recipe_client

      delivered = run_in_fork do
        client.postfork # after_fork { |_s, _w| client.postfork } / on_event(:starting_worker_process)
        recorder = install_recording_http_client(client)
        variation = recipe_bucket(client)
        client.flush("child")
        { variation_id: variation.is_a?(ConvertSdk::BucketedVariation) ? variation.id : nil,
          requests: recorder.requests }
      end

      expect(delivered[:variation_id]).to eq(RuntimeRecipeHelpers::RECIPE_VARIATION_ID)
      expect(delivered_visitor_ids(delivered[:requests].first[:body]))
        .to eq([RuntimeRecipeHelpers::RECIPE_VISITOR])
    end
  end

  describe "recipe: sidekiq-shutdown-flush" do
    # Sidekiq OSS is threaded, single-process, no fork. A singleton client is reused
    # across (simulated) threaded job invocations that enqueue events; the
    # config.on(:shutdown) { client.flush } hook delivers the remaining queue at
    # shutdown. Runs everywhere (no fork) — including JRuby.
    it "singleton reused across threaded jobs -> shutdown flush delivers remaining events" do
      client = build_recipe_client
      stub_recipe_track

      # Simulated threaded job invocations: each "job" buckets a distinct visitor on
      # the SAME singleton client. Bounded join (no sleep-and-hope).
      threads = %w[job-visitor-a job-visitor-b job-visitor-c].map do |vid|
        Thread.new { client.create_context(vid, RuntimeRecipeHelpers::RECIPE_ATTRIBUTES).run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY) }
      end
      threads.each { |t| t.join(2) }

      expect(client.api_manager.queue.size).to eq(3) # queued, not yet delivered
      client.flush("shutdown") # the config.on(:shutdown) hook body

      expect(captured_requests.size).to eq(1)
      expect(delivered_visitor_ids(captured_request.body))
        .to contain_exactly("job-visitor-a", "job-visitor-b", "job-visitor-c")
      expect(client.api_manager.queue.size).to eq(0)
    end
  end

  describe "recipe: aws-lambda-sync-flush" do
    # Lambda freezes the execution environment between invocations — background
    # threads are useless/harmful. Timer-off mode (data_refresh_interval: nil +
    # flush_interval: nil) + a SYNCHRONOUS flush before the handler returns is the
    # recipe. Assert ZERO background threads existed throughout. Runs everywhere.
    it "timer-off + synchronous flush delivers all events with zero background threads" do
      stub_recipe_track

      baseline = Thread.list.size
      client = build_recipe_client(flush_interval: nil, data_refresh_interval: nil)

      # The handler shape: create context, decide, track, SYNCHRONOUS flush, return.
      handler = lambda do |visitor_id|
        ctx = client.create_context(visitor_id, RuntimeRecipeHelpers::RECIPE_ATTRIBUTES)
        variation = ctx.run_experience(RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY)
        client.flush("handler-return") # MUST be synchronous — env freezes after
        variation
      end
      variation = handler.call(RuntimeRecipeHelpers::RECIPE_VISITOR)
      thread_delta = Thread.list.size - baseline

      expect(variation).to be_a(ConvertSdk::BucketedVariation)
      expect(thread_delta).to eq(0) # NFR4 — timer-off never spawned a thread
      expect(captured_requests.size).to eq(1)
      expect(delivered_visitor_ids(captured_request.body)).to eq([RuntimeRecipeHelpers::RECIPE_VISITOR])
    end
  end

  describe "recipe: plain-cli-at-exit", :fork do
    before { skip_unless_fork_supported }

    # A subprocess running a small script (create -> use -> normal exit). The
    # PID-guarded at_exit flush (4.4) fires on normal exit and delivers. Evidence is
    # the flush reason written to stdout (the script swaps release_queue for a
    # tagged stdout write — the same Open3 harness shape as fork_safety_spec).
    it "subprocess normal exit fires the PID-guarded at_exit flush" do
      out, status = run_cli_recipe_probe

      expect(status.success?).to be(true)
      flush_lines = out.lines.grep(/FLUSHED:/)
      expect(flush_lines.size).to eq(1)
      expect(flush_lines.first).to include("FLUSHED:exit")
    end
  end

  # The plain-CLI subprocess: a self-contained script that builds a REAL factory
  # client (at_exit registration ON — this is a fresh process, not the RSpec one),
  # buckets the known visitor, and falls off the end so its at_exit flush fires. The
  # flush is observed by swapping release_queue for a tagged stdout write (avoids a
  # live network POST while still proving the at_exit path ran on normal exit).
  def run_cli_recipe_probe
    lib = File.expand_path("../../lib", __dir__)
    fixture = File.expand_path("../fixtures/test-config.json", __dir__)
    Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", cli_recipe_script(fixture))
  end

  def cli_recipe_script(fixture)
    <<~RUBY
      require "convert_sdk"
      require "json"
      data = JSON.parse(File.read(#{fixture.inspect}))
      client = ConvertSdk.create(data: data, sdk_key: "sdk-key-1")
      # Observe the at_exit flush without a live POST: tag the reason to stdout.
      client.api_manager.define_singleton_method(:release_queue) do |reason = nil|
        $stdout.puts("FLUSHED:" + reason.to_s); $stdout.flush
      end
      ctx = client.create_context("cli-visitor", #{RuntimeRecipeHelpers::RECIPE_ATTRIBUTES.inspect})
      ctx.run_experience(#{RuntimeRecipeHelpers::RECIPE_EXPERIENCE_KEY.inspect})
      # falls off the end -> PID-guarded at_exit flush fires -> FLUSHED:exit
    RUBY
  end
end
