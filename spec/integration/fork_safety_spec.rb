# frozen_string_literal: true

require "spec_helper"
require "open3"

# Story 4.4 (AC#7) — the integration proof for the SDK's signature differentiator:
# zero-config fork safety. Each AC maps to a named example. Real-fork examples are
# CRuby-only (skip_unless_fork_supported); the JRuby matrix leg asserts the no-op
# layers as free checks. WebMock does not cross fork for child-side assertions, so
# child-delivery proofs use a RecordingHttpClient whose array is Marshalled back
# through run_in_fork's return-value pipe. The at_exit guard is proven in a real
# SUBPROCESS (never an unguarded at_exit inside the RSpec process).
RSpec.describe "Fork safety integration (Story 4.4)" do
  before { reset_fork_guard! }
  after { reset_fork_guard! }

  describe "AC#1 — zero threads after the factory (lazy start, nothing to lose at fork)" do
    it "spawns NO threads across ConvertSdk.create (Thread.list delta zero vs baseline)" do
      # Baseline: Ruby-internal threads present BEFORE the factory (GC, finalizers)
      # — subtracting it removes the flakiness the story warns about.
      baseline = Thread.list.size
      client = ConvertSdk.create(data: { "data" => { "account_id" => "a", "project_id" => "p" } })
      delta = Thread.list.size - baseline

      expect(client).to be_a(ConvertSdk::Client)
      expect(delta).to eq(0)
    end
  end

  describe "AC#2 — automatic child re-arm + child delivers (the _fork hook)", :fork do
    before { skip_unless_fork_supported }

    it "(a) preload shape: create in parent (no use) -> fork -> child tracks -> child delivers" do
      ConvertSdk::ForkGuard.install!
      manager, = build_recording_api_manager # parent builds, never enqueues
      ConvertSdk::ForkGuard.register_timer(double_dead_timer)

      child_requests = run_in_fork do
        # The _fork hook already ran (marked timers dead, cleared the queue). The
        # child enqueues its own event and delivers it from the child.
        manager.enqueue("child-visitor", fork_event("e1", "v1"))
        manager.release_queue("child")
        manager.instance_variable_get(:@http_client).requests
      end

      expect(child_requests.size).to eq(1)
      expect(child_requests.first[:body]["visitors"].first["visitorId"]).to eq("child-visitor")
    end

    it "(b) post-use fork: child timers dead, child enqueue re-arms + delivers, parent unaffected" do
      ConvertSdk::ForkGuard.install!
      manager, parent_http = build_recording_api_manager
      # Parent uses the SDK first (queues a parent event; its timer would be alive).
      manager.enqueue("parent-visitor", fork_event("ep", "vp"))

      child_requests = run_in_fork do
        # Child inherited a COPY of the parent's queue; the _fork hook cleared it,
        # so the child starts EMPTY (no double-delivery of the parent's event).
        started_empty = manager.queue.size.zero? # rubocop:disable Style/ZeroLengthPredicate
        manager.enqueue("child-visitor", fork_event("ec", "vc"))
        manager.release_queue("child")
        delivered = manager.instance_variable_get(:@http_client).requests
        { started_empty: started_empty, delivered: delivered }
      end

      expect(child_requests[:started_empty]).to be(true)
      ids = child_requests[:delivered].first[:body]["visitors"].map { |v| v["visitorId"] }
      expect(ids).to eq(["child-visitor"]) # ONLY the child's event — parent's not double-delivered
      # Parent is unaffected: its own event is still queued (it delivers it itself).
      expect(parent_http.requests).to be_empty
      expect(manager.queue.size).to eq(1)
    end
  end

  describe "AC#3 — PID-boundary daemon simulation (Process.daemon bypasses _fork)" do
    it "(c) a stale owner_pid at a flush boundary triggers ForkGuard.rearm!" do
      manager, http = build_recording_api_manager
      manager.enqueue("pre-daemon", fork_event("e", "v"))
      # Daemon simulation: owner_pid no longer matches (the _fork hook never ran).
      ConvertSdk::ForkGuard.instance_variable_set(:@owner_pid, -1)

      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original
      manager.release_queue("explicit")

      # Re-arm cleared the inherited queue (no delivery of the pre-daemon event).
      expect(http.requests).to be_empty
      expect(manager.queue.size).to eq(0)
    end
  end

  describe "AC#4 — postfork delegates to the same re-arm path" do
    it "(d) Client#postfork invokes ForkGuard.rearm! (spy)" do
      client = ConvertSdk.create(data: { "data" => { "account_id" => "a", "project_id" => "p" } })

      expect(ConvertSdk::ForkGuard).to receive(:rearm!).and_call_original
      client.postfork
    end
  end

  describe "AC#5 — PID-guarded at_exit (proven in a subprocess)", :fork do
    before { skip_unless_fork_supported }

    it "(e) the registering process flushes at exit; a forked child does NOT" do
      # A self-contained script: create a client whose ApiManager records to a
      # file (the cross-process flush evidence), enqueue one event, then fork. The
      # child exits first (its inherited at_exit must be SUPPRESSED). The parent
      # exits last (its at_exit must FIRE -> flush -> evidence written).
      out, status = run_at_exit_probe

      expect(status.success?).to be(true)
      # Exactly one flush-evidence line — from the PARENT only (child suppressed).
      flush_lines = out.lines.grep(/FLUSHED:/)
      expect(flush_lines.size).to eq(1)
      expect(flush_lines.first).to include("FLUSHED:parent")
    end
  end

  describe "JRuby no-op layers (free checks, not skipped)" do
    it "ForkGuard.forked? is false and the at_exit PID-guard trivially passes when fork is unsupported" do
      # forked? is a pure PID comparison: in the owning process (no fork ever) it
      # is false — the same value JRuby always returns. The at_exit guard
      # (Process.pid == registered_pid) is correspondingly always true.
      expect(ConvertSdk::ForkGuard.forked?).to be(false)
      client = ConvertSdk.create(data: { "data" => { "account_id" => "a", "project_id" => "p" } })
      expect(client.instance_variable_get(:@at_exit_pid)).to eq(Process.pid)
    end
  end

  # A duck-typed dead-markable timer for the registry (mirrors fork_guard_spec).
  def double_dead_timer
    Class.new do
      def mark_dead; end
    end.new
  end

  # Run the at_exit probe subprocess and return [stdout, Process::Status]. The
  # script lives inline (-e) so no fixture file is needed; it requires the gem
  # from this checkout's lib via -I.
  def run_at_exit_probe
    lib = File.expand_path("../../lib", __dir__)
    script = at_exit_probe_script
    Open3.capture2e(RbConfig.ruby, "-I", lib, "-e", script)
  end

  # The inline probe: a client whose flush writes "FLUSHED:<role>" to stdout via a
  # recording manager, then forks. The child exits immediately (its inherited
  # at_exit must be suppressed by the PID guard); the parent waits, then exits
  # (its at_exit fires the flush).
  def at_exit_probe_script
    <<~RUBY
      require "convert_sdk"
      client = ConvertSdk.create(data: { "data" => { "account_id" => "a", "project_id" => "p" } })
      # Replace release_queue so the flush leaves observable evidence tagged by role.
      role = "parent"
      client.api_manager.define_singleton_method(:release_queue) do |reason = nil|
        $stdout.puts("FLUSHED:" + role + ":" + reason.to_s); $stdout.flush
      end
      pid = fork do
        role = "child"
        exit(0) # child exits -> inherited at_exit must be SUPPRESSED (pid mismatch)
      end
      Process.wait(pid)
      # parent falls off the end -> its at_exit fires -> FLUSHED:parent:exit
    RUBY
  end
end
