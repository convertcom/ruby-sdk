# frozen_string_literal: true

require "spec_helper"

# Story 4.4 — Client-level fork safety: the public #postfork escape hatch and
# the PID-guarded single-site at_exit flush. The at_exit handler body is tested
# DIRECTLY (run_at_exit_flush) so no real at_exit handler is registered inside
# the RSpec process (which would fire at suite exit); the live-registration path
# is proven end-to-end via a SUBPROCESS in spec/integration/fork_safety_spec.rb.
RSpec.describe "Client fork safety (Story 4.4)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(data: {}, config_endpoint: HttpStubs::CONFIG_HOST) }

  before { reset_fork_guard! }
  after { reset_fork_guard! }

  # Build a Client through the constructor with real collaborators (mirrors
  # client_spec's never-crash helper). at_exit registration is globally disabled
  # in the test harness (spec_helper), so constructing here is side-effect-free.
  def build_client(api_manager: nil)
    http_client = ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1)
    em = ConvertSdk::EventManager.new(log_manager: log_manager)
    dm = ConvertSdk::DataManager.new(log_manager: log_manager)
    am = api_manager || ConvertSdk::ApiManager.new(
      config: config, data_manager: dm, http_client: http_client, event_manager: em, log_manager: log_manager
    )
    ConvertSdk::Client.new(
      config: config, log_manager: log_manager, http_client: http_client,
      data_store_manager: ConvertSdk::DataStoreManager.new(log_manager: log_manager),
      event_manager: em, data_manager: dm, api_manager: am
    )
  end

  describe "#postfork (AC#4 — frozen API name)" do
    it "delegates to the same ForkGuard.rearm! path as automatic detection" do
      client = build_client
      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original
      client.postfork
    end

    it "is idempotent — repeated calls re-arm without raising" do
      client = build_client
      expect { client.postfork.postfork }.not_to raise_error
    end

    it "returns self (chainable) and never raises into the host" do
      client = build_client
      allow(ConvertSdk::ForkGuard).to receive(:rearm!).and_raise(StandardError, "boom")
      expect { @result = client.postfork }.not_to raise_error
      expect(@result).to eq(client)
    end
  end

  describe "PID-guarded at_exit flush (AC#5)" do
    it "flushes with reason 'exit' when run in the registering process" do
      api_manager = instance_double(ConvertSdk::ApiManager)
      allow(api_manager).to receive(:release_queue)
      client = build_client(api_manager: api_manager)

      # The handler body runs in the registering process (PID matches).
      client.send(:run_at_exit_flush)

      expect(api_manager).to have_received(:release_queue).with("exit")
    end

    it "suppresses the flush when run in a forked child (PID mismatch)" do
      api_manager = instance_double(ConvertSdk::ApiManager)
      allow(api_manager).to receive(:release_queue)
      client = build_client(api_manager: api_manager)

      # Simulate a child: the captured registering PID no longer matches.
      client.instance_variable_set(:@at_exit_pid, -1)
      client.send(:run_at_exit_flush)

      expect(api_manager).not_to have_received(:release_queue)
    end

    it "logs the at_exit fire and suppression at the ClassName#method format" do
      client = build_client
      client.send(:run_at_exit_flush) # registering process -> fires
      expect(sink.joined).to match(/Client#run_at_exit_flush:/)

      client.instance_variable_set(:@at_exit_pid, -1)
      client.send(:run_at_exit_flush) # child -> suppressed
      expect(sink.joined).to match(/Client#run_at_exit_flush:.*(suppress|child)/i)
    end

    it "never raises at exit even if the flush raises" do
      api_manager = instance_double(ConvertSdk::ApiManager)
      allow(api_manager).to receive(:release_queue).and_raise(StandardError, "exit boom")
      client = build_client(api_manager: api_manager)

      expect { client.send(:run_at_exit_flush) }.not_to raise_error
    end

    it "captures the registering PID at construction" do
      client = build_client
      expect(client.instance_variable_get(:@at_exit_pid)).to eq(Process.pid)
    end
  end

  describe "single at_exit site (architectural regression)" do
    it "is the only file under lib/ that registers an at_exit handler" do
      lib_root = File.expand_path("../../lib", __dir__)
      offenders = Dir[File.join(lib_root, "**", "*.rb")].select do |path|
        File.read(path).match?(/^\s*at_exit\b/)
      end
      expect(offenders.map { |p| File.basename(p) }).to eq(["client.rb"])
    end
  end

  describe "at_exit registration suppression hook" do
    it "exposes a module flag the test harness uses to opt out of live registration" do
      expect(ConvertSdk).to respond_to(:at_exit_registration_enabled?)
    end
  end
end
