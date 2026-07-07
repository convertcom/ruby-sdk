# frozen_string_literal: true

require "spec_helper"

# RB-3 (qs-03 AC4 fetch resolution / AC8 memoization) —
# #get_config_by_experience's query-param composition table. Top-level
# constant (RuboCop forbids constants inside blocks — see
# spec/unit/client_spec.rb for the same convention). Cross-product over
# debug_token (set/unset) x environment (set/nil); exp=<id> and
# _conv_low_cache=1 are asserted unconditionally in the example itself (never
# part of the row) since the contract requires them ALWAYS present.
CONFIG_BY_EXPERIENCE_URL_TABLE = {
  "no environment, no debug_token" => { environment: nil, debug_token: nil },
  "environment set, no debug_token" => { environment: "staging", debug_token: nil },
  "no environment, debug_token set" => { environment: nil, debug_token: "tok-123" },
  "environment set, debug_token set" => { environment: "staging", debug_token: "tok-123" }
}.freeze

RSpec.describe ConvertSdk::ApiManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::DEBUG, sink: sink) }
  let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }

  let(:vendored) { vendored_config }
  let(:data_manager) do
    ConvertSdk::DataManager.new(log_manager: log_manager).tap { |m| m.install_config(vendored) }
  end

  # Track endpoint with the [project_id] placeholder so the builder must replace it.
  let(:track_endpoint) { "#{HttpStubs::TRACK_HOST}/[project_id]/v1" }

  def build_api_manager(secret: nil, event_batch_size: 10, flush_interval: nil,
                        sdk_key: "sdk-key-1", config_endpoint: HttpStubs::CONFIG_HOST,
                        environment: nil, debug_token: nil)
    config = ConvertSdk::Config.new(
      data: vendored,
      sdk_key: sdk_key,
      sdk_key_secret: secret,
      config_endpoint: config_endpoint,
      environment: environment,
      debug_token: debug_token,
      track_endpoint: track_endpoint,
      event_batch_size: event_batch_size,
      flush_interval: flush_interval
    )
    described_class.new(
      config: config,
      data_manager: data_manager,
      http_client: http_client,
      event_manager: event_manager,
      log_manager: log_manager
    )
  end

  # Parse a URL's query string into a plain Hash for param-presence/composition
  # assertions (RB-3 / qs-03 AC4) — mirrors spec/unit/client_spec.rb's helper of
  # the same name (kept per-file, matching that file's existing convention of
  # not extracting this 5-line helper to spec/support).
  def query_params(url)
    query = URI.parse(url).query
    return {} if query.nil?

    URI.decode_www_form(query).to_h
  end

  # Subject: timer-off by default so the explicit-release/payload specs below are
  # unaffected by a background flush timer (those predate Story 4.2's timer).
  subject(:api_manager) { build_api_manager }

  # The ApiManager's flush BackgroundTimer instance (2.7's introspection pattern).
  def flush_timer(manager)
    manager.instance_variable_get(:@flush_timer)
  end

  # Drive one flush-timer tick deterministically (no real sleep) — 2.7's pattern.
  def tick_flush(manager)
    manager.send(:flush_tick)
  end

  # The URL the builder must POST to: track_endpoint with [project_id] replaced,
  # then /track/{sdkKey}. Stub it by regex (project id substituted in).
  def stub_track_endpoint(status: 200)
    stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
      .with(&capture)
      .to_return(status: status, body: JSON.generate(canned_ack), headers: json_headers)
  end

  describe "#release_queue payload (AC#2)" do
    it "POSTs the golden string-keyed camelCase payload to the project-scoped track URL" do
      stub_track_endpoint
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      api_manager.release_queue("test")

      # captured_request asserts exactly one request reached the wire. (We avoid
      # WebMock's have_been_requested here: it re-evaluates the capturing `with`
      # matcher, which would double-record into captured_requests.)
      expect(captured_request.uri).to include("/10025986/v1/track/sdk-key-1")
      sent = JSON.parse(captured_request.body)
      expect(sent).to eq(
        expected_track_payload(
          account_id: "10022898",
          project_id: "10025986",
          visitors: [
            {
              "visitorId" => "v1",
              "events" => [bucketing_event(experience_id: "e1", variation_id: "var1")]
            }
          ]
        )
      )
    end

    it "carries no symbol keys anywhere — the generated JSON round-trips to string keys" do
      stub_track_endpoint
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"),
                          segments: { "visitorType" => "new" })

      api_manager.release_queue("test")

      reparsed = JSON.parse(captured_request.body)
      symbol_keys = collect_keys(reparsed).grep_v(String)
      expect(symbol_keys).to be_empty
      expect(reparsed["visitors"].first["segments"]).to eq("visitorType" => "new")
    end

    # Walk a parsed graph collecting every hash key (to prove none are symbols).
    def collect_keys(node)
      case node
      when Hash then node.flat_map { |k, v| [k, *collect_keys(v)] }
      when Array then node.flat_map { |e| collect_keys(e) }
      else []
      end
    end
  end

  describe "#release_queue Bearer header (AC#2)" do
    it "attaches Authorization: Bearer when a secret is configured" do
      stub_track_endpoint
      manager = build_api_manager(secret: "topsecret")
      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      manager.release_queue("test")

      expect(captured_request.headers["Authorization"]).to eq("Bearer topsecret")
    end

    it "sends no Authorization header when no secret is configured" do
      stub_track_endpoint
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      api_manager.release_queue("test")

      expect(captured_request.headers).not_to have_key("Authorization")
    end
  end

  describe "#release_queue empty-queue no-op (AC#2)" do
    it "makes no HTTP request when the queue is empty" do
      stub_track_endpoint

      api_manager.release_queue("test")

      expect(captured_requests).to be_empty
    end
  end

  describe "#release_queue I/O outside the lock (NFR2)" do
    it "lets a concurrent enqueue return immediately during a slow POST" do
      # A POST that blocks ~0.3s; the concurrent enqueue must not wait on it.
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return do
          sleep(0.3)
          { status: 200, body: JSON.generate(canned_ack) }
        end

      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      releaser = Thread.new { api_manager.release_queue("slow") }
      # Give the releaser time to enter the (outside-the-lock) POST.
      sleep(0.05)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      api_manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2"))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.1 # enqueue did not block on the in-flight POST
      releaser.join
    end
  end

  describe "#release_queue failure retention (Story 4.2 AC#3)" do
    it "does not raise on a failed POST and warns that it is retaining the events" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return(status: 500, body: "")
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect { api_manager.release_queue("test") }.not_to raise_error
      warns = sink.entries.filter_map { |level, message| message if level == :warn }
      expect(warns).to include(a_string_matching(/delivery failed, retaining 1 events/))
    end

    it "retains the drained events in the queue after a failed POST (no inline retry)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return(status: 500, body: "")
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      api_manager.release_queue("test")

      expect(api_manager.queue.size).to eq(1)
    end

    it "does NOT fire API_QUEUE_RELEASED on a failed POST (frozen divergence from JS)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return(status: 500, body: "")
      received = []
      event_manager.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |payload, err| received << [payload, err] }
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      api_manager.release_queue("test")

      expect(received).to be_empty
    end

    it "redelivers all retained events exactly once on the next release (fail then succeed)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .with(&capture)
        .to_return(status: 500, body: "").then
        .to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      api_manager.enqueue("v1", bucketing_event(experience_id: "e2", variation_id: "var2"))

      api_manager.release_queue("first")  # 500 → retained
      api_manager.release_queue("second") # 200 → delivered

      # Two POST attempts were made; the SECOND carried all retained events once.
      expect(captured_requests.size).to eq(2)
      delivered = JSON.parse(captured_requests.last.body)
      expect(delivered["visitors"]).to eq([
                                            {
                                              "visitorId" => "v1",
                                              "events" => [
                                                bucketing_event(experience_id: "e1", variation_id: "var1"),
                                                bucketing_event(experience_id: "e2", variation_id: "var2")
                                              ]
                                            }
                                          ])
    end

    it "retains and redelivers across a transport timeout then success (sequenced)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .with(&capture)
        .to_timeout.then
        .to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      api_manager.release_queue("first")  # timeout → failed Response → retained
      expect(api_manager.queue.size).to eq(1)
      api_manager.release_queue("second") # 200 → delivered exactly once

      delivered = JSON.parse(captured_requests.last.body)
      expect(delivered["visitors"]).to eq([
                                            {
                                              "visitorId" => "v1",
                                              "events" => [bucketing_event(experience_id: "e1", variation_id: "var1")]
                                            }
                                          ])
    end

    it "preserves per-visitor merge when new events arrive between the failure and the retry" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .with(&capture)
        .to_return(status: 500, body: "").then
        .to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      api_manager.release_queue("first") # 500 → e1 retained
      # A new event for the SAME visitor arrives during the outage.
      api_manager.enqueue("v1", bucketing_event(experience_id: "e2", variation_id: "var2"))

      api_manager.release_queue("second") # 200 → delivers both, merged, no duplicate entry

      delivered = JSON.parse(captured_requests.last.body)
      expect(delivered["visitors"].size).to eq(1)
      expect(delivered["visitors"].first["events"]).to eq([
                                                            bucketing_event(experience_id: "e1", variation_id: "var1"),
                                                            bucketing_event(experience_id: "e2", variation_id: "var2")
                                                          ])
    end
  end

  describe "#release_queue success event (Story 4.2 AC#4)" do
    it "fires API_QUEUE_RELEASED on success with the reason and visitor count" do
      stub_track_endpoint
      received = []
      event_manager.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |payload, err| received << [payload, err] }
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      api_manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2"))

      api_manager.release_queue("interval")

      expect(received).to eq([[{ "reason" => "interval", "visitors" => 2 }, nil]])
    end
  end

  describe "batch-size trigger (Story 4.2 AC#1)" do
    it "releases automatically when the queue reaches event_batch_size, on the enqueuing thread" do
      stub_track_endpoint
      manager = build_api_manager(event_batch_size: 3, flush_interval: nil)

      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2"))
      expect(captured_requests).to be_empty # below threshold → no release yet
      manager.enqueue("v3", bucketing_event(experience_id: "e3", variation_id: "var3"))

      # The third enqueue hit the threshold → released synchronously, queue drained.
      expect(captured_requests.size).to eq(1)
      expect(manager.queue.size).to eq(0)
    end

    [1, 2, 5].each do |batch_size|
      it "honors a configurable event_batch_size of #{batch_size}" do
        stub_track_endpoint
        manager = build_api_manager(event_batch_size: batch_size, flush_interval: nil)

        (batch_size - 1).times do |i|
          manager.enqueue("v#{i}", bucketing_event(experience_id: "e#{i}", variation_id: "var#{i}"))
        end
        expect(captured_requests.size).to eq(0)
        manager.enqueue("vN", bucketing_event(experience_id: "eN", variation_id: "varN"))

        expect(captured_requests.size).to eq(1)
        expect(manager.queue.size).to eq(0)
      end
    end

    it "tags the auto-release with reason 'size'" do
      stub_track_endpoint
      manager = build_api_manager(event_batch_size: 1, flush_interval: nil)
      received = []
      event_manager.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |payload, _err| received << payload }

      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect(received).to eq([{ "reason" => "size", "visitors" => 1 }])
    end

    it "runs the size-trigger POST outside the queue lock (a concurrent enqueue is not blocked)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return do
          sleep(0.3)
          { status: 200, body: JSON.generate(canned_ack) }
        end
      # batch_size 2: the releaser thread's SECOND enqueue fires the size release
      # and enters the slow POST; a concurrent enqueue (which stays BELOW the
      # threshold, so it triggers no release of its own) must not wait on that
      # in-flight POST — proving the POST is outside the queue lock (NFR2).
      manager = build_api_manager(event_batch_size: 2, flush_interval: nil)

      releaser = Thread.new do
        manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
        manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2")) # → size release, slow POST
      end
      sleep(0.05) # let the releaser enter the outside-the-lock POST

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      manager.enqueue("v3", bucketing_event(experience_id: "e3", variation_id: "var3")) # size 1 < 2 → no trigger
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 0.1
      releaser.join
    end
  end

  describe "lazily-started flush timer (Story 4.2 AC#1, #2)" do
    it "never starts a timer in the constructor (NFR4 — no threads until first use)" do
      manager = build_api_manager(flush_interval: 1)
      expect(flush_timer(manager).alive?).to be(false)
    end

    it "starts the flush timer on the first enqueue and registers it with ForkGuard" do
      stub_track_endpoint
      manager = build_api_manager(flush_interval: 1)

      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect(flush_timer(manager).alive?).to be(true)
      registered = ConvertSdk::ForkGuard.instance_variable_get(:@timers)
      expect(registered).to include(flush_timer(manager))
      flush_timer(manager).stop
    end

    it "releases the queue on a timer tick with reason 'interval'" do
      stub_track_endpoint
      manager = build_api_manager(flush_interval: 1)
      received = []
      event_manager.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |payload, _err| received << payload }
      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      tick_flush(manager)

      expect(received).to eq([{ "reason" => "interval", "visitors" => 1 }])
      manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2"))
      flush_timer(manager)&.stop
    end

    it "delivers on its own thread when started (real short-interval loop)" do
      stub_track_endpoint
      manager = build_api_manager(flush_interval: 0.02)
      delivered = Queue.new
      event_manager.on(ConvertSdk::SystemEvents::API_QUEUE_RELEASED) { |_payload, _err| delivered << true }

      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      # Bounded wait for one real tick on the timer thread (no Timeout, no sleep
      # loop). The timer keeps looping at 20ms; STOP it in an ensure so the
      # thread cannot outlive this example (and fire a stray POST into the next
      # example's WebMock) even if the assertion raises. The global after-hook
      # reap is the backstop; this is the local guarantee.
      expect(delivered.pop).to be(true)
    ensure
      flush_timer(manager)&.stop
    end

    context "timer-off mode (flush_interval: nil — Lambda recipe 4.6)" do
      it "never creates a flush timer thread" do
        stub_track_endpoint
        manager = build_api_manager(flush_interval: nil)

        manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

        expect(flush_timer(manager).alive?).to be(false)
      end

      it "still delivers via the size trigger" do
        stub_track_endpoint
        manager = build_api_manager(flush_interval: nil, event_batch_size: 1)

        manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

        expect(captured_requests.size).to eq(1)
      end

      it "still delivers via an explicit release" do
        stub_track_endpoint
        manager = build_api_manager(flush_interval: nil, event_batch_size: 100)
        manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

        manager.release_queue("explicit")

        expect(captured_requests.size).to eq(1)
      end
    end
  end

  # Fix 1 — enqueue before rearm (daemon bypass data-loss fix, Story 4.4).
  #
  # When Process.daemon bypasses the _fork hook, ForkGuard.forked? returns true
  # (owner_pid is stale). The original enqueue() called guard_fork_boundary AFTER
  # queuing the event — meaning the child callback (clear_queue_ownership) fired
  # AFTER the event was appended, wiping it. The fix moves guard_fork_boundary to
  # the TOP of enqueue(), so the inherited queue is cleared BEFORE the child's own
  # event is added, and the event survives to delivery.
  describe "enqueue-before-rearm: daemon-bypass event not lost (Fix 1)" do
    it "an event enqueued while stale (daemon-bypass simulation) survives to flush" do
      stub_track_endpoint
      manager = build_api_manager(flush_interval: nil)

      # Simulate daemon-bypass: set owner_pid stale so ForkGuard.forked? is true.
      # This is the same simulation used by the integration fork_safety_spec (AC#3).
      original_pid = ConvertSdk::ForkGuard.owner_pid
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      # enqueue() now calls guard_fork_boundary FIRST (clears the inherited empty
      # queue), then adds the new event — the event must survive.
      manager.enqueue("child-visitor", bucketing_event(experience_id: "e1", variation_id: "v1"))
      manager.release_queue("test")

      expect(captured_requests.size).to eq(1)
      delivered = JSON.parse(captured_requests.first.body)
      ids = delivered["visitors"].map { |v| v["visitorId"] }
      expect(ids).to eq(["child-visitor"])
    ensure
      # Restore owner_pid so other examples are unaffected (reset_for_tests! in
      # after-hook covers this too, but an ensure is an explicit safety net).
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, original_pid)
    end

    it "guard_fork_boundary is called at the top of enqueue (not just in release_queue)" do
      manager = build_api_manager(flush_interval: nil)

      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)
      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original.at_least(:once)

      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "v1"))
    ensure
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, Process.pid)
    end
  end

  describe "outage boundedness (Story 4.2 AC#3 — NFR10)" do
    it "never grows the queue past 1000 under sustained failure + continuous enqueue" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return(status: 500, body: "")
      manager = build_api_manager(event_batch_size: 50, flush_interval: nil)

      # Enqueue far more than the cap; the size trigger keeps firing, each POST
      # fails and retains, so the queue must stay bounded at MAX_EVENTS (1000).
      1500.times { |i| manager.enqueue("v#{i % 7}", bucketing_event(experience_id: "e#{i}", variation_id: "var#{i}")) }

      expect(manager.queue.size).to be <= 1000
      warns = sink.entries.filter_map { |level, message| message if level == :warn }
      expect(warns.grep(/VisitorsQueue#trim_to_cap/)).not_to be_empty
    end
  end

  # RB-3 (qs-03 AC4 fetch resolution / AC8 memoization) — ApiManager#get_config_by_experience.
  #
  # JS oracle: packages/api/src/api-manager.ts#getConfigByExperience (branch
  # feat/experiment-preview, commit b719795, ~line 344) — a module-level
  # `configByExperienceCache` Map keyed `${sdkKey}:${experienceId}`, 60s TTL,
  # query params ordered environment (when set) -> exp -> _conv_low_cache=1
  # (always) -> debug_token (when set).
  #
  # The memo is PROCESS-WIDE (a module-level cache shared by every ApiManager
  # instance — mirroring the JS module-level Map), so every example resets it
  # via the (not-yet-implemented) `ApiManager.reset_config_by_experience_cache_for_tests!`
  # test-only seam — guarded with `respond_to?` so this file loads/fails
  # cleanly on the missing `#get_config_by_experience` method during the RED
  # phase, before that reset seam exists, rather than failing inside the hook
  # itself. Mirrors ForkGuard.reset_for_tests! (fork_guard.rb) — the SDK's only
  # other process-wide-state test-reset precedent.
  describe "#get_config_by_experience (RB-3 / qs-03 AC4 fetch resolution, AC8 memoization)" do
    before do
      if ConvertSdk::ApiManager.respond_to?(:reset_config_by_experience_cache_for_tests!)
        ConvertSdk::ApiManager.reset_config_by_experience_cache_for_tests!
      end
    end

    after do
      if ConvertSdk::ApiManager.respond_to?(:reset_config_by_experience_cache_for_tests!)
        ConvertSdk::ApiManager.reset_config_by_experience_cache_for_tests!
      end
    end

    describe "URL composition (AC4)" do
      CONFIG_BY_EXPERIENCE_URL_TABLE.each do |label, row|
        it "always carries exp=<id> and _conv_low_cache=1 for #{label}" do
          stub_vendored_config
          manager = build_api_manager(environment: row[:environment], debug_token: row[:debug_token])

          manager.get_config_by_experience("123")

          params = query_params(captured_request.uri)
          expect(params["exp"]).to eq("123")
          expect(params["_conv_low_cache"]).to eq("1")
          if row[:environment]
            expect(params["environment"]).to eq(row[:environment])
          else
            expect(params).not_to have_key("environment")
          end
          if row[:debug_token]
            expect(params["debug_token"]).to eq(row[:debug_token])
          else
            expect(params).not_to have_key("debug_token")
          end
        end
      end

      it "orders params as environment, then exp, then _conv_low_cache, then debug_token when all four compose" do
        manager = build_api_manager(environment: "staging", debug_token: "tok-123")

        expect(manager.send(:config_by_experience_url, "123")).to eq(
          "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1?environment=staging&exp=123&_conv_low_cache=1&debug_token=tok-123"
        )
      end

      it "fetches through @http_client with the Bearer auth header when a secret is configured" do
        stub_vendored_config
        manager = build_api_manager(secret: "topsecret")

        manager.get_config_by_experience("123")

        expect(captured_request.headers["Authorization"]).to eq("Bearer topsecret")
      end
    end

    describe "memoization (AC8)" do
      it "fires exactly one HTTP request for two lookups of the same (sdk_key, experience_id) within the TTL" do
        stub_vendored_config
        manager = build_api_manager

        first = manager.get_config_by_experience("123")
        second = manager.get_config_by_experience("123")

        expect(captured_requests.size).to eq(1)
        expect(second).to eq(first)
        expect(first).to eq(vendored)
      end
    end

    describe "key isolation" do
      it "fetches again for a different experience_id on the same manager (no cross-experience collision)" do
        stub_vendored_config
        manager = build_api_manager

        manager.get_config_by_experience("123")
        manager.get_config_by_experience("456")

        expect(captured_requests.size).to eq(2)
      end

      it "fetches again for the same experience_id under a different sdk_key (no cross-tenant collision)" do
        stub_vendored_config(sdk_key: "sdk-key-1")
        stub_vendored_config(sdk_key: "sdk-key-2")
        manager_a = build_api_manager(sdk_key: "sdk-key-1")
        manager_b = build_api_manager(sdk_key: "sdk-key-2")

        manager_a.get_config_by_experience("123")
        manager_b.get_config_by_experience("123")

        expect(captured_requests.size).to eq(2)
      end
    end

    # TTL is wall-clock (60s), per the qs-03 spec ("in-memory only ... TTL 60 s
    # (in-memory only; never the store)") and the JS oracle's `Date.now()`.
    # Stubbing `Time.now` (rather than injecting a `clock:` constructor seam)
    # keeps every OTHER example in this file's `build_api_manager` call sites
    # unaffected, and keeps this RED phase's failures uniformly attributable to
    # the missing `#get_config_by_experience` method rather than an
    # ArgumentError from an unrecognized constructor keyword. GREEN-phase note:
    # the implementation's wall-clock TTL check MUST read `Time.now` (e.g.
    # `Time.now.to_f`), not `Process.clock_gettime(Process::CLOCK_MONOTONIC)`,
    # for these two examples to observe the stubbed clock.
    describe "TTL expiry (60s wall clock)" do
      it "refetches once the memoized entry is older than 60 seconds" do
        stub_vendored_config
        manager = build_api_manager
        now = Time.now
        allow(Time).to receive(:now) { now }

        manager.get_config_by_experience("123")
        now += 61
        manager.get_config_by_experience("123")

        expect(captured_requests.size).to eq(2)
      end

      it "does not refetch just short of 60 seconds (still memoized)" do
        stub_vendored_config
        manager = build_api_manager
        now = Time.now
        allow(Time).to receive(:now) { now }

        manager.get_config_by_experience("123")
        now += 59
        manager.get_config_by_experience("123")

        expect(captured_requests.size).to eq(1)
      end
    end

    # FIX-1 (code review round 1, qs-03 AC8 hardening) — `experience_id` comes
    # from the operator/attacker-influenced `convert_preview={expId}.{varId}`
    # link param, so a stream of distinct experience_ids must NOT accumulate
    # unbounded entries in the process-wide `@config_by_experience_cache`
    # Hash (only cleared on fork or process exit otherwise). JS oracle sweeps
    # expired entries on every write (api-manager.ts ~367-370); this asserts
    # the Ruby memo does the same — not merely that an expired LOOKUP returns
    # nil (already covered above), but that the underlying Hash actually
    # shrinks on the next write. Uses the same `Time.now` stub convention as
    # the "TTL expiry" examples above (a `clock:` seam is not exercised here).
    describe "process-wide eviction on write (memory-growth guard, FIX-1)" do
      it "sweeps expired entries from the class-level cache when a new entry is memoized" do
        stub_vendored_config
        manager = build_api_manager
        now = Time.now
        allow(Time).to receive(:now) { now }

        manager.get_config_by_experience("111")
        manager.get_config_by_experience("222")
        manager.get_config_by_experience("333")
        expect(ConvertSdk::ApiManager.config_by_experience_cache_size_for_tests).to eq(3)

        now += 61
        manager.get_config_by_experience("444")

        expect(ConvertSdk::ApiManager.config_by_experience_cache_size_for_tests).to eq(1)
      end
    end

    describe "no store interaction (AC8 — never the store)" do
      it "never reads or writes the store while resolving or memoizing" do
        store_spy = instance_double(ConvertSdk::DataStoreManager)
        expect(store_spy).not_to receive(:get)
        expect(store_spy).not_to receive(:set)
        dm = ConvertSdk::DataManager.new(
          log_manager: log_manager, data_store_manager: store_spy, config_key: "convert_sdk.config.sdk-key-1"
        )
        config = ConvertSdk::Config.new(data: vendored, sdk_key: "sdk-key-1", config_endpoint: HttpStubs::CONFIG_HOST)
        manager = described_class.new(
          config: config, data_manager: dm, http_client: http_client,
          event_manager: event_manager, log_manager: log_manager
        )
        stub_vendored_config

        manager.get_config_by_experience("123")
        manager.get_config_by_experience("123") # second call within TTL — still no store touch
      end
    end
  end
end
