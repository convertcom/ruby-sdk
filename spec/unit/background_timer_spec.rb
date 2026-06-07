# frozen_string_literal: true

require "spec_helper"

# A thread-safe tick counter that signals waiters; the tick block bumps it and
# specs wait on it with a bounded {TickCounter#wait_for} (no flaky sleeps).
class TickCounter
  def initialize
    @mutex = Thread::Mutex.new
    @cv = Thread::ConditionVariable.new
    @count = 0
  end

  def bump
    @mutex.synchronize do
      @count += 1
      @cv.signal
    end
  end

  def value
    @mutex.synchronize { @count }
  end

  # Block (bounded) until the count reaches +target+; true if reached.
  def wait_for(target, timeout: 2.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    @mutex.synchronize do
      until @count >= target
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        break if remaining <= 0

        @cv.wait(@mutex, remaining)
      end
      @count >= target
    end
  end
end

RSpec.describe ConvertSdk::BackgroundTimer do
  let(:sink) { CapturingSink.new }
  # TRACE so debug-level thread-creation logs are captured.
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }

  # Build a timer whose tick bumps a thread-safe counter so specs can wait for
  # N ticks with a BOUNDED wait rather than a flaky bare sleep.
  def counting_timer(interval: 0.02, name: "test", &on_tick)
    counter = TickCounter.new
    timer = described_class.new(interval: interval, log_manager: log_manager, name: name) do
      on_tick&.call
      counter.bump
    end
    [timer, counter]
  end

  describe "#start / #stop idempotence" do
    it "starts a live thread on first start and is alive" do
      timer, * = counting_timer
      timer.start
      expect(timer.alive?).to be(true)
      timer.stop
    end

    it "does not spawn a second thread when start is called twice" do
      timer, * = counting_timer
      timer.start
      first_thread = timer.instance_variable_get(:@thread)
      timer.start
      expect(timer.instance_variable_get(:@thread)).to be(first_thread)
      timer.stop
    end

    it "is a no-op (does not raise) when stop is called without start" do
      timer, * = counting_timer
      expect { timer.stop }.not_to raise_error
      expect(timer.alive?).to be(false)
    end

    it "is a no-op when stop is called twice" do
      timer, * = counting_timer
      timer.start
      timer.stop
      expect { timer.stop }.not_to raise_error
      expect(timer.alive?).to be(false)
    end
  end

  describe "tick firing" do
    it "fires the block repeatedly on its interval" do
      timer, counter = counting_timer(interval: 0.02)
      timer.start
      expect(counter.wait_for(3)).to be(true)
      timer.stop
    end

    it "logs thread creation at debug" do
      timer, * = counting_timer(name: "refresh")
      timer.start
      timer.stop
      expect(sink.entries).to include([:debug, a_string_matching(/BackgroundTimer#start.*refresh/)])
    end
  end

  describe "never-crash tick" do
    it "logs a raising tick and keeps the loop alive for the next tick" do
      raised = 0
      timer, counter = counting_timer(interval: 0.02) do
        raised += 1
        raise StandardError, "boom" if raised == 1
      end
      timer.start
      # Despite the first tick raising, subsequent ticks must still fire.
      expect(counter.wait_for(2)).to be(true)
      expect(timer.alive?).to be(true)
      timer.stop
      expect(sink.joined).to match(/BackgroundTimer#test: tick raised.*StandardError.*boom/)
    end
  end

  describe "#mark_dead and lazy re-arm" do
    it "is not alive after mark_dead and re-arms a NEW thread on start" do
      timer, * = counting_timer
      timer.start
      original = timer.instance_variable_get(:@thread)
      timer.mark_dead
      expect(timer.alive?).to be(false)
      timer.start
      expect(timer.alive?).to be(true)
      expect(timer.instance_variable_get(:@thread)).not_to be(original)
      timer.stop
    end
  end

  describe "no block supplied" do
    it "ticks without raising when constructed without a block" do
      timer = described_class.new(interval: 0.02, log_manager: log_manager, name: "noblock")
      timer.start
      # Give the loop time to tick at least once against an absent block.
      sleep(0.05)
      expect(timer.alive?).to be(true)
      timer.stop
    end
  end

  describe "timer-off guard" do
    it "never starts when interval is nil" do
      timer = described_class.new(interval: nil, log_manager: log_manager, name: "off") { raise "should not tick" }
      timer.start
      expect(timer.alive?).to be(false)
    end

    it "never starts when interval is zero" do
      timer = described_class.new(interval: 0, log_manager: log_manager, name: "off") { raise "should not tick" }
      timer.start
      expect(timer.alive?).to be(false)
    end
  end

  describe "concurrent start" do
    it "produces exactly one thread under a start race" do
      timer, * = counting_timer
      threads = Array.new(10) { Thread.new { timer.start } }
      threads.each(&:join)
      expect(timer.alive?).to be(true)
      # Only one underlying loop thread is ever created.
      expect(timer.instance_variable_get(:@thread)).to be_a(Thread)
      timer.stop
    end
  end

  describe "single Thread.new site (architectural regression)" do
    it "is the only file under lib/ that references Thread.new" do
      lib_root = File.expand_path("../../lib", __dir__)
      offenders = Dir[File.join(lib_root, "**", "*.rb")].select do |path|
        File.read(path).include?("Thread.new")
      end
      expect(offenders.map { |p| File.basename(p) }).to eq(["background_timer.rb"])
    end
  end
end
