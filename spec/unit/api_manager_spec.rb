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

  def build_api_manager(secret: nil)
    config = ConvertSdk::Config.new(
      data: vendored["data"],
      sdk_key: "sdk-key-1",
      sdk_key_secret: secret,
      track_endpoint: track_endpoint
    )
    described_class.new(
      config: config,
      data_manager: data_manager,
      http_client: http_client,
      event_manager: event_manager,
      log_manager: log_manager
    )
  end

  subject(:api_manager) { build_api_manager }

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

  describe "#release_queue failure boundary" do
    it "does not raise on a failed POST (4.2 owns retention; never-crash here)" do
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .to_return(status: 500, body: "")
      api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect { api_manager.release_queue("test") }.not_to raise_error
    end
  end
end
