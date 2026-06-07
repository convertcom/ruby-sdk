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
end

RSpec.configure do |config|
  config.include ForkHelpers
end
