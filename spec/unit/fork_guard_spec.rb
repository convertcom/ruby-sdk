# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# A minimal duck-typed timer recording whether it was marked dead.
class FakeTimer
  attr_reader :dead

  def initialize
    @dead = false
  end

  def mark_dead
    @dead = true
  end
end

RSpec.describe ConvertSdk::ForkGuard do
  before { reset_fork_guard! }
  after { reset_fork_guard! }

  describe ".forked? and owner_pid tracking" do
    it "is false in the owning process" do
      expect(described_class.forked?).to be(false)
    end

    it "tracks the current pid as owner_pid after reset/arm" do
      expect(described_class.owner_pid).to eq(Process.pid)
    end
  end

  describe ".register_timer + .rearm!" do
    it "marks every registered timer dead on rearm!" do
      t1 = FakeTimer.new
      t2 = FakeTimer.new
      described_class.register_timer(t1)
      described_class.register_timer(t2)
      described_class.rearm!
      expect([t1.dead, t2.dead]).to eq([true, true])
    end

    it "resets owner_pid to the current pid on rearm!" do
      described_class.instance_variable_set(:@owner_pid, -1)
      described_class.rearm!
      expect(described_class.owner_pid).to eq(Process.pid)
    end
  end

  describe ".register_child_callback + .rearm!" do
    it "fires callbacks in registration order, after timers are marked dead" do
      order = []
      timer = FakeTimer.new
      described_class.register_timer(timer)
      described_class.register_child_callback(-> { order << :first })
      described_class.register_child_callback(-> { order << :second })
      # A callback can observe that timers were already marked dead.
      described_class.register_child_callback(-> { order << (timer.dead ? :timer_dead : :timer_alive) })
      described_class.rearm!
      expect(order).to eq(%i[first second timer_dead])
    end
  end

  describe "double-install guard" do
    it "installs the prepend at most once" do
      # install! is idempotent: a second call must not add another prepend.
      described_class.install!
      before_ancestors = Process.singleton_class.ancestors.count { |m| m.to_s.include?("ForkGuard") }
      described_class.install!
      after_ancestors = Process.singleton_class.ancestors.count { |m| m.to_s.include?("ForkGuard") }
      expect(after_ancestors).to eq(before_ancestors)
    end
  end

  describe "JRuby no-op branch" do
    it "skips the prepend and keeps forked? false when fork is unsupported" do
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:fork).and_return(false)
      # Re-running install! under the stub must not raise and must remain inert.
      expect { described_class.install! }.not_to raise_error
      expect(described_class.forked?).to be(false)
    end
  end

  describe "nil-safe logger before wiring" do
    it "does not raise on rearm! when no logger has been wired" do
      described_class.logger = nil
      expect { described_class.rearm! }.not_to raise_error
    end

    it "debug-logs fork detection when a logger is wired" do
      sink = CapturingSink.new
      log_manager = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
      described_class.logger = log_manager
      described_class.rearm!
      expect(sink.joined).to match(/ForkGuard/)
    end
  end

  describe "actual fork integration (CRuby only)", :fork do
    before { skip_unless_fork_supported }

    # The _fork hook fires automatically in the child and runs the shared
    # re-arm path: it resets owner_pid to the child's pid (so the child is now
    # the owner — forked? is correctly false afterward, there is nothing left to
    # re-arm), marks registered timers dead, and fires child-callbacks. The
    # parent is unaffected. We assert these EFFECTS — owner_pid reset is the
    # observable proof the hook ran in the child.

    it "resets owner_pid to the child pid via the _fork hook, leaving the parent unaffected" do
      described_class.install!
      parent_pid = Process.pid
      child_owner_matches = run_in_fork do
        # owner_pid was reset by the hook to this child's pid.
        ConvertSdk::ForkGuard.owner_pid == Process.pid && Process.pid != parent_pid
      end
      expect(child_owner_matches).to be(true)
      # Parent still owns its own threads; it did not fork-detect itself.
      expect(described_class.forked?).to be(false)
      expect(described_class.owner_pid).to eq(parent_pid)
    end

    it "marks registered timers dead in the child via the _fork hook" do
      described_class.install!
      described_class.register_timer(FakeTimer.new)
      child_dead = run_in_fork { ConvertSdk::ForkGuard.instance_variable_get(:@timers).first.dead }
      expect(child_dead).to be(true)
    end

    it "fires registered child-callbacks in the child via the _fork hook" do
      described_class.install!
      # The callback writes a sentinel to a file the parent reads back.
      tmp = "#{Dir.tmpdir}/forkguard_cb_#{Process.pid}_#{rand(10_000)}"
      described_class.register_child_callback(-> { File.write(tmp, "fired") })
      run_in_fork { :done }
      expect(File.exist?(tmp)).to be(true)
      expect(File.read(tmp)).to eq("fired")
    ensure
      File.delete(tmp) if tmp && File.exist?(tmp)
    end
  end

  describe "single Process._fork prepend site (architectural regression)" do
    it "is the only file under lib/ that defines _fork or prepends onto the singleton class" do
      lib_root = File.expand_path("../../lib", __dir__)
      offenders = Dir[File.join(lib_root, "**", "*.rb")].select do |path|
        src = File.read(path)
        # The actual global mutation (singleton_class.prepend) and the hook
        # definition (def _fork) — not comment prose mentioning "_fork".
        src.include?("singleton_class.prepend") || src.match?(/^\s*def _fork\b/)
      end
      expect(offenders.map { |p| File.basename(p) }).to eq(["fork_guard.rb"])
    end
  end
end
