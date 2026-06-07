# frozen_string_literal: true

require "spec_helper"

# Every SystemEvents constant paired with its verbatim JS wire string, so the
# parity surface (FR57) is asserted in one tabular sweep rather than ten
# copy-pasted examples. Top-level (RuboCop forbids constants defined in a block).
EVENT_MANAGER_ALL_EVENTS = {
  "READY" => ConvertSdk::SystemEvents::READY,
  "CONFIG_UPDATED" => ConvertSdk::SystemEvents::CONFIG_UPDATED,
  "BUCKETING" => ConvertSdk::SystemEvents::BUCKETING,
  "CONVERSION" => ConvertSdk::SystemEvents::CONVERSION,
  "API_QUEUE_RELEASED" => ConvertSdk::SystemEvents::API_QUEUE_RELEASED,
  "SEGMENTS" => ConvertSdk::SystemEvents::SEGMENTS,
  "LOCATION_ACTIVATED" => ConvertSdk::SystemEvents::LOCATION_ACTIVATED,
  "LOCATION_DEACTIVATED" => ConvertSdk::SystemEvents::LOCATION_DEACTIVATED,
  "AUDIENCES" => ConvertSdk::SystemEvents::AUDIENCES,
  "DATASTORE_QUEUE_RELEASED" => ConvertSdk::SystemEvents::DATASTORE_QUEUE_RELEASED
}.freeze

RSpec.describe ConvertSdk::EventManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  subject(:manager) { described_class.new(log_manager: log_manager) }

  # Captures listener invocations as [payload, err] without each test
  # hand-rolling its own accumulator (kills cross-case duplication).
  def recorder
    captured = []
    listener = ->(payload, err = nil) { captured << [payload, err] }
    [captured, listener]
  end

  describe "registration parity (AC#1)" do
    it "registers a SystemEvents constant and its string under the same key" do
      via_const = []
      via_string = []
      manager.on(ConvertSdk::SystemEvents::READY) { |payload| via_const << payload }
      manager.on("ready") { |payload| via_string << payload }

      manager.fire(ConvertSdk::SystemEvents::READY, :hello)

      expect(via_const).to eq([:hello])
      expect(via_string).to eq([:hello])
    end

    it "delivers the payload to the listener" do
      captured, listener = recorder
      manager.on("bucketing", &listener)
      manager.fire("bucketing", { variation: 1 })
      expect(captured).to eq([[{ variation: 1 }, nil]])
    end

    it "fires multiple listeners in registration order" do
      order = []
      manager.on("segments") { order << :first }
      manager.on("segments") { order << :second }
      manager.on("segments") { order << :third }
      manager.fire("segments")
      expect(order).to eq(%i[first second third])
    end

    it "passes err = nil on normal emission and accepts single-param blocks" do
      seen = []
      manager.on("conversion") { |payload| seen << payload } # single-param block
      manager.fire("conversion", 42)
      expect(seen).to eq([42])
    end

    it "passes err as the second argument when supplied" do
      captured, listener = recorder
      manager.on("config.updated", &listener)
      boom = RuntimeError.new("nope")
      manager.fire("config.updated", nil, boom)
      expect(captured).to eq([[nil, boom]])
    end

    context "tabular: every SystemEvents constant registers and fires under its verbatim JS string" do
      EVENT_MANAGER_ALL_EVENTS.each do |name, wire|
        it "#{name} == #{wire.inspect}: constant and string register the same listener" do
          via_const = []
          via_string = []
          manager.on(wire) { via_const << :c }        # registered via the constant value
          manager.on(wire.to_s) { via_string << :s }  # registered via the literal string
          manager.fire(wire)
          expect(via_const).to eq([:c])
          expect(via_string).to eq([:s])
        end
      end
    end

    it "fires unknown/unregistered events to zero listeners silently (debug log)" do
      expect { manager.fire("never.registered", :x) }.not_to raise_error
      expect(sink.joined).to include("never.registered")
    end
  end

  describe "thread-safe registration + snapshot firing (AC#2)" do
    it "tolerates concurrent registration while firing (no concurrent-modification error)" do
      gate = Thread::Queue.new
      # A slow listener holds the fire loop open while other threads register.
      manager.on("audiences") do
        gate.pop # block until the registering threads have run
      end

      registrars = Array.new(8) do |i|
        Thread.new do
          manager.on("audiences") { i }
        end
      end

      fire_thread = Thread.new { manager.fire("audiences") }
      sleep 0.05
      registrars.each(&:join) # all registered while fire is mid-flight
      gate.push(:go)          # release the slow listener
      expect { fire_thread.join }.not_to raise_error
    end

    it "does not deadlock when a listener re-registers during firing" do
      added = []
      manager.on("api.queue.released") do
        manager.on("api.queue.released") { added << :late }
      end
      expect { manager.fire("api.queue.released") }.not_to raise_error
      # The late listener was added but not invoked in the same fire (snapshot).
      manager.fire("api.queue.released")
      expect(added).to eq([:late])
    end
  end

  describe "listener exception containment (AC#3)" do
    it "catches and logs a raising listener and still fires siblings" do
      after_raise = []
      manager.on("location.activated") { raise StandardError, "listener boom" }
      manager.on("location.activated") { after_raise << :ran }

      expect { manager.fire("location.activated") }.not_to raise_error
      expect(after_raise).to eq([:ran])
      expect(sink.joined).to include("EventManager#fire:")
      expect(sink.joined).to include("location.activated")
      expect(sink.joined).to include("StandardError")
    end
  end

  describe "deferred-replay (AC#1)" do
    it "replays a stored deferred event to a late subscriber" do
      manager.fire(ConvertSdk::SystemEvents::READY, :ready_payload, deferred: true)
      captured, listener = recorder
      manager.on(ConvertSdk::SystemEvents::READY, &listener)
      expect(captured).to eq([[:ready_payload, nil]])
    end

    it "replays both payload and err to a late subscriber" do
      err = RuntimeError.new("late err")
      manager.fire("conversion", :conv, err, deferred: true)
      captured, listener = recorder
      manager.on("conversion", &listener)
      expect(captured).to eq([[:conv, err]])
    end

    it "does not replay non-deferred events to late subscribers" do
      manager.fire("bucketing", :missed)
      captured, listener = recorder
      manager.on("bucketing", &listener)
      expect(captured).to be_empty
    end

    it "keeps the first deferred payload when fired again (first deferred wins for storage)" do
      manager.fire("segments", :first, deferred: true)
      manager.fire("segments", :second, deferred: true)
      captured, listener = recorder
      manager.on("segments", &listener)
      expect(captured).to eq([[:first, nil]])
    end
  end
end
