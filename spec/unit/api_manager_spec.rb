# frozen_string_literal: true

require "spec_helper"

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

  def build_api_manager(secret: nil, event_batch_size: 10, flush_interval: nil)
    config = ConvertSdk::Config.new(
      data: vendored["data"],
      sdk_key: "sdk-key-1",
      sdk_key_secret: secret,
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

    it "never blocks the enqueuing caller on the size-trigger POST (POST outside the lock)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return do
          sleep(0.3)
          { status: 200, body: JSON.generate(canned_ack) }
        end
      manager = build_api_manager(event_batch_size: 1, flush_interval: nil)

      # The size trigger releases on THIS thread, but the POST runs outside the
      # queue lock — a concurrent enqueue must not wait on the in-flight POST.
      releaser = Thread.new { manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1")) }
      sleep(0.05)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      manager.enqueue("v2", bucketing_event(experience_id: "e2", variation_id: "var2"))
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

      # Bounded wait for one real tick on the timer thread (no Timeout, no sleep loop).
      expect(delivered.pop).to be(true)
      flush_timer(manager).stop
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
      expect(warns).to include("VisitorsQueue#enqueue: queue full, dropping oldest event")
    end
  end
end
