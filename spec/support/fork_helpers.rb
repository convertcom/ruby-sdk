# frozen_string_literal: true

# Helpers for the fork-aware infrastructure specs (Story 2.6).
#
# JRuby has no +fork+, so every spec that actually forks a child process MUST
# guard with {#skip_unless_fork_supported}; the JRuby matrix leg then exercises
# only the no-op / free-check branches. Real-fork specs run on CRuby only.
#
# {#run_in_fork} forks a child, runs the block, and ships the block's return
# value back to the parent over a pipe (Marshal-encoded). The child is ALWAYS
# reaped with +Process.wait+ — no zombie processes are left in CI. Exceptions in
# the child are captured and re-raised in the parent so a failing child
# assertion surfaces as a normal example failure rather than a silent exit.
#
# {#reset_fork_guard!} restores {ConvertSdk::ForkGuard} module state between
# examples (owner_pid, timer registry, child-callback registry, logger) so the
# singleton-state module is order-independent under RSpec.
module ForkHelpers
  # Skip the current example unless the runtime supports real +fork+ (CRuby).
  # @return [void]
  def skip_unless_fork_supported
    skip("fork not supported on #{RUBY_ENGINE}") unless Process.respond_to?(:fork)
  end

  # Fork a child, run +block+ in it, and return the block's value in the parent.
  #
  # The child Marshal-dumps +{ value: ... }+ (or +{ error: ... }+) down a pipe;
  # the parent reads it, waits on the child (no zombies), and either returns the
  # value or re-raises the child-side error. Caller MUST have already invoked
  # {#skip_unless_fork_supported}.
  #
  # @yield runs in the forked child process.
  # @return [Object] the block's return value, transported from the child.
  def run_in_fork(&block)
    reader, writer = IO.pipe
    pid = fork { run_fork_child(reader, writer, &block) }
    writer.close
    raw = reader.read
    reader.close
    Process.wait(pid)
    payload = Marshal.load(raw) # rubocop:disable Security/MarshalLoad
    raise "child raised #{payload[:error]}" if payload.key?(:error)

    payload[:value]
  end

  # Runs in the forked child: evaluate the block, ship the result down the pipe,
  # then hard-exit (skipping at_exit hooks / RSpec teardown).
  def run_fork_child(reader, writer)
    reader.close
    payload =
      begin
        { value: yield }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end
    writer.write(Marshal.dump(payload))
    writer.close
    exit!(0)
  end

  # Reset {ConvertSdk::ForkGuard} singleton state so specs are order-independent.
  # @return [void]
  def reset_fork_guard!
    ConvertSdk::ForkGuard.reset_for_tests!
  end

  # Story 4.4 — a recording fake of the {ConvertSdk::HttpClient} port for
  # child-delivery proofs. WebMock stubs live in process-global tables; a forked
  # child inherits a COPY and cannot record invocations back to the parent, so
  # WebMock cannot assert what the CHILD delivered. This fake instead RECORDS each
  # request into an in-process array — the child's array is Marshalled back to the
  # parent through {#run_in_fork}'s return-value pipe, giving a clean assertion of
  # exactly what the child POSTed. Always returns a 200 (delivery succeeds).
  class RecordingHttpClient
    # @return [Array<Hash>] every request seen, as +{method:, url:, body:}+.
    attr_reader :requests

    def initialize
      @requests = []
    end

    # Duck-types {ConvertSdk::HttpClient#request}; returns a success Response.
    # +headers+ is part of the port contract (kept for signature fidelity) but
    # unused by the recorder.
    def request(method:, url:, body: nil, headers: {}) # rubocop:disable Lint/UnusedMethodArgument
      @requests << { method: method, url: url, body: body }
      ConvertSdk::HttpClient::Response.new(status: 200, body: {}, headers: {})
    end
  end

  # Build an {ConvertSdk::ApiManager} wired to a {RecordingHttpClient} so that
  # delivery (parent OR child) is assertable by inspecting +http_client.requests+.
  # The manager and its recording client are returned together.
  #
  # @param flush_interval [Numeric, nil] the flush-timer interval (nil = off).
  # @return [Array(ConvertSdk::ApiManager, RecordingHttpClient)]
  def build_recording_api_manager(flush_interval: nil)
    log_manager = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::ERROR)
    http_client = RecordingHttpClient.new
    event_manager = ConvertSdk::EventManager.new(log_manager: log_manager)
    config = ConvertSdk::Config.new(
      data: { "data" => { "account_id" => "acc", "project_id" => "proj" } },
      sdk_key: "sdk-key-1", track_endpoint: "https://track.example/[project_id]/v1",
      event_batch_size: 100, flush_interval: flush_interval
    )
    data_manager = ConvertSdk::DataManager.new(log_manager: log_manager)
    data_manager.install_config({ "data" => { "account_id" => "acc", "project_id" => "proj" } })
    manager = ConvertSdk::ApiManager.new(
      config: config, data_manager: data_manager, http_client: http_client,
      event_manager: event_manager, log_manager: log_manager
    )
    [manager, http_client]
  end

  # A wire-shaped bucketing event (string-keyed camelCase) for fork specs.
  # @return [Hash{String=>Object}]
  def fork_event(experience_id, variation_id)
    {
      "eventType" => "bucketing",
      "data" => { "experienceId" => experience_id, "variationId" => variation_id }
    }
  end
end

RSpec.configure do |config|
  config.include ForkHelpers
end
