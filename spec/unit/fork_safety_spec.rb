# frozen_string_literal: true

require "spec_helper"

# Story 4.4 — unit-level fork-safety composition (the actual-fork integration
# proofs live in spec/integration/fork_safety_spec.rb).
#
# Two surfaces are exercised here without forking:
#   * ApiManager registers exactly ONE ForkGuard child-callback that clears its
#     queue (child starts empty — no double-delivery), and the PID check at the
#     SINGLE release entry (#release_queue) re-arms a stale process before
#     proceeding (covers Process.daemon, which bypasses the _fork hook).
#   * Logging at the PID-mismatch boundary and the queue-ownership clear.
RSpec.describe "Fork-safety composition (Story 4.4)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }
  let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }
  let(:vendored) { vendored_config }
  let(:data_manager) do
    ConvertSdk::DataManager.new(log_manager: log_manager).tap { |m| m.install_config(vendored) }
  end
  let(:track_endpoint) { "#{HttpStubs::TRACK_HOST}/[project_id]/v1" }

  # ForkGuard is process-global singleton state — reset around every example so
  # registration counts and owner_pid are deterministic and order-independent.
  before { reset_fork_guard! }
  after { reset_fork_guard! }

  def build_api_manager(flush_interval: nil)
    config = ConvertSdk::Config.new(
      data: vendored, sdk_key: "sdk-key-1", track_endpoint: track_endpoint,
      event_batch_size: 100, flush_interval: flush_interval
    )
    ConvertSdk::ApiManager.new(
      config: config, data_manager: data_manager, http_client: http_client,
      event_manager: event_manager, log_manager: log_manager
    )
  end

  def stub_track_ok
    stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
      .to_return(status: 200, body: JSON.generate({}), headers: { "Content-Type" => "application/json" })
  end

  # The child-callbacks ForkGuard would fire on a real fork.
  def child_callbacks
    ConvertSdk::ForkGuard.instance_variable_get(:@child_callbacks)
  end

  describe "ApiManager queue-ownership child-callback (AC#2)" do
    it "registers exactly one child-callback at construction" do
      before_count = child_callbacks.size
      build_api_manager
      expect(child_callbacks.size - before_count).to eq(1)
    end

    it "clears its inherited queue when the registered child-callback fires" do
      manager = build_api_manager
      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      expect(manager.queue.size).to eq(1)

      # Simulate the child path: ForkGuard fires the registered callbacks.
      child_callbacks.each(&:call)

      expect(manager.queue.size).to eq(0)
    end

    it "logs the queue-ownership clear at debug with the ClassName#method format" do
      manager = build_api_manager
      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      child_callbacks.each(&:call)

      expect(sink.joined).to match(/ApiManager#.*queue.*clear/i)
    end
  end

  describe "PID check at the single release entry (AC#3 — Process.daemon bypass)" do
    it "re-arms via ForkGuard.rearm! when the process is stale at a flush boundary" do
      manager = build_api_manager
      # Daemon simulation: owner_pid no longer matches this process, so
      # ForkGuard.forked? is true without the _fork hook having run.
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original

      manager.release_queue("explicit")
    end

    it "re-arms even when the queue is empty (boundary fires before the empty-queue return)" do
      manager = build_api_manager
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original

      manager.release_queue("explicit") # empty queue
    end

    it "does NOT re-arm when the process is the owner (no fork)" do
      manager = build_api_manager
      stub_track_ok
      manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect(ConvertSdk::ForkGuard).not_to receive(:rearm!)

      manager.release_queue("explicit")
    end

    it "logs the PID-mismatch detection at the flush boundary" do
      manager = build_api_manager
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      manager.release_queue("explicit")

      expect(sink.joined).to match(/ApiManager:.*(stale|fork|pid)/i)
    end

    it "delivers from the re-armed process after rearm (queue cleared, fresh enqueue delivers)" do
      manager = build_api_manager
      stub_track_ok
      # Pre-fork events sit in the queue; daemon-style staleness then a fresh
      # enqueue + release in the "child".
      manager.enqueue("parent", bucketing_event(experience_id: "ep", variation_id: "vp"))
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      # First boundary detects staleness, rearms (clears the inherited queue).
      manager.release_queue("explicit")
      expect(manager.queue.size).to eq(0)

      # Now the re-armed process enqueues its own event and delivers it.
      manager.enqueue("child", bucketing_event(experience_id: "ec", variation_id: "vc"))
      manager.release_queue("explicit")
      expect(a_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")).to have_been_made.at_least_once
    end
  end
end
