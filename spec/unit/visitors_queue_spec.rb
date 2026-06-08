# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::VisitorsQueue do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::DEBUG, sink: sink) }
  subject(:queue) { described_class.new(log_manager: log_manager) }

  # A wire-shaped bucketing event (string-keyed camelCase) — the only shape the
  # queue ever holds. A tiny factory keeps every example free of inline literals.
  def event(experience_id, variation_id)
    {
      "eventType" => "bucketing",
      "data" => { "experienceId" => experience_id, "variationId" => variation_id }
    }
  end

  describe "#enqueue per-visitor merge (AC#1)" do
    it "creates one entry per new visitor with its first event" do
      queue.enqueue("v1", event("e1", "var1"))

      visitors = queue.drain!
      expect(visitors.size).to eq(1)
      expect(visitors.first["visitorId"]).to eq("v1")
      expect(visitors.first["events"]).to eq([event("e1", "var1")])
    end

    it "appends to an existing visitor's events array — never a duplicate entry" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v1", event("e2", "var2"))

      visitors = queue.drain!
      expect(visitors.size).to eq(1)
      expect(visitors.first["visitorId"]).to eq("v1")
      expect(visitors.first["events"]).to eq([event("e1", "var1"), event("e2", "var2")])
    end

    it "keeps separate entries for distinct visitors (never a flat event list)" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v2", event("e2", "var2"))

      visitors = queue.drain!
      expect(visitors.map { |v| v["visitorId"] }).to contain_exactly("v1", "v2")
      expect(visitors).to all(satisfy { |v| v.key?("events") && !v.key?("event") })
    end

    it "sets segments only on the visitor's first entry, omitting them when nil" do
      queue.enqueue("v1", event("e1", "var1"), segments: { "visitorType" => "new" })
      queue.enqueue("v1", event("e2", "var2"), segments: { "visitorType" => "ignored" })
      queue.enqueue("v2", event("e3", "var3"))

      visitors = queue.drain!
      v1 = visitors.find { |v| v["visitorId"] == "v1" }
      v2 = visitors.find { |v| v["visitorId"] == "v2" }
      expect(v1["segments"]).to eq("visitorType" => "new")
      expect(v2).not_to have_key("segments")
    end
  end

  describe "#size event count" do
    it "counts events, not visitors" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v1", event("e2", "var2"))
      queue.enqueue("v2", event("e3", "var3"))

      expect(queue.size).to eq(3)
    end

    it "is zero on a fresh queue and after a drain" do
      expect(queue.size).to eq(0)
      queue.enqueue("v1", event("e1", "var1"))
      queue.drain!
      expect(queue.size).to eq(0)
    end
  end

  describe "cap 1000 drop-oldest + warn (AC#1)" do
    it "bounds the queue at 1000 events, dropping the OLDEST on overflow" do
      1000.times { |i| queue.enqueue("v#{i}", event("e#{i}", "var#{i}")) }
      expect(queue.size).to eq(1000)

      queue.enqueue("v-new", event("e-new", "var-new"))

      expect(queue.size).to eq(1000)
      visitors = queue.drain!
      ids = visitors.map { |v| v["visitorId"] }
      expect(ids).not_to include("v0")       # oldest dropped
      expect(ids).to include("v-new")        # newest retained
    end

    it "removes a visitor entry once its last event is dropped" do
      1000.times { queue.enqueue("only", event("e", "var")) }
      # 'only' holds all 1000 events; one overflow drops its oldest event.
      queue.enqueue("fresh", event("ef", "varf"))

      visitors = queue.drain!
      only = visitors.find { |v| v["visitorId"] == "only" }
      expect(only["events"].size).to eq(999)
      expect(visitors.map { |v| v["visitorId"] }).to include("fresh")
    end

    it "warns once per dropped event" do
      1000.times { |i| queue.enqueue("v#{i}", event("e#{i}", "var#{i}")) }
      queue.enqueue("v-new", event("e-new", "var-new"))

      warns = sink.entries.filter_map { |level, message| message if level == :warn }
      expect(warns).to include("VisitorsQueue#enqueue: queue full, dropping oldest event")
    end
  end

  describe "#drain! atomic drain-and-swap" do
    it "returns the drained visitors and leaves the queue empty" do
      queue.enqueue("v1", event("e1", "var1"))

      drained = queue.drain!
      expect(drained.first["visitorId"]).to eq("v1")
      expect(queue.size).to eq(0)
      expect(queue.drain!).to eq([])
    end

    it "yields re-enqueueable data (per-visitor merge preserved on round-trip)" do
      queue.enqueue("v1", event("e1", "var1"))
      drained = queue.drain!

      drained.each do |visitor|
        visitor["events"].each { |ev| queue.enqueue(visitor["visitorId"], ev) }
      end
      queue.enqueue("v1", event("e2", "var2"))

      visitors = queue.drain!
      expect(visitors.size).to eq(1)
      expect(visitors.first["events"]).to eq([event("e1", "var1"), event("e2", "var2")])
    end

    it "stays consistent under concurrent enqueue during repeated drains" do
      enqueued = 0
      writer = Thread.new do
        500.times do |i|
          queue.enqueue("v#{i % 5}", event("e#{i}", "var#{i}"))
          enqueued += 1
        end
      end

      total_drained = 0
      total_drained += queue.drain!.sum { |v| v["events"].size } until writer.join(0)
      total_drained += queue.drain!.sum { |v| v["events"].size }

      # Every one of the 500 enqueues lands in exactly one drain — none lost,
      # none double-counted — proving drain-and-swap is atomic against enqueue.
      expect(enqueued).to eq(500)
      expect(total_drained).to eq(500)
      expect(queue.size).to eq(0)
    end
  end

  describe "#requeue merge-preserving re-enqueue (Story 4.2 failure retention)" do
    # The retention path: ApiManager drains, a POST fails, and the drained
    # visitors are re-enqueued. The drained events are OLDER than anything the
    # queue received during the failed POST, so they must precede new events for
    # the same visitor — and never spawn a duplicate visitor entry.

    it "restores drained entries into an empty queue verbatim" do
      queue.enqueue("v1", event("e1", "var1"), segments: { "visitorType" => "new" })
      drained = queue.drain!

      queue.requeue(drained)

      visitors = queue.drain!
      expect(visitors.size).to eq(1)
      expect(visitors.first["visitorId"]).to eq("v1")
      expect(visitors.first["events"]).to eq([event("e1", "var1")])
      expect(visitors.first["segments"]).to eq("visitorType" => "new")
    end

    it "tracks event count after a requeue" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v1", event("e2", "var2"))
      drained = queue.drain!

      queue.requeue(drained)
      expect(queue.size).to eq(2)
    end

    it "merges a drained visitor into a same-visitor entry that gained new events, oldest first" do
      # Drain v1's first event, then new events arrive for v1 before the requeue.
      queue.enqueue("v1", event("e1", "var1"))
      drained = queue.drain!
      queue.enqueue("v1", event("e2", "var2"))

      queue.requeue(drained)

      visitors = queue.drain!
      expect(visitors.size).to eq(1)
      expect(visitors.first["visitorId"]).to eq("v1")
      # Drained (older) event precedes the event enqueued during the failure.
      expect(visitors.first["events"]).to eq([event("e1", "var1"), event("e2", "var2")])
    end

    it "keeps distinct drained visitors as separate entries" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v2", event("e2", "var2"))
      drained = queue.drain!

      queue.requeue(drained)

      visitors = queue.drain!
      expect(visitors.map { |v| v["visitorId"] }).to contain_exactly("v1", "v2")
      expect(visitors).to all(satisfy { |v| v["events"].size == 1 })
    end

    it "adopts a drained entry's segments when the existing entry has none" do
      queue.enqueue("v1", event("e1", "var1"), segments: { "visitorType" => "new" })
      drained = queue.drain!
      queue.enqueue("v1", event("e2", "var2")) # no segments on the new entry

      queue.requeue(drained)

      visitors = queue.drain!
      expect(visitors.first["segments"]).to eq("visitorType" => "new")
    end

    it "is a no-op for an empty drained array" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.requeue([])

      expect(queue.size).to eq(1)
    end

    it "bounds the queue at 1000 on requeue overflow, dropping oldest + warn (NFR10)" do
      # Simulate sustained outage: the queue is already near cap with newer
      # events, and a large drained batch is requeued on top.
      900.times { |i| queue.enqueue("live#{i}", event("e#{i}", "var#{i}")) }
      drained = (0...300).map do |i|
        { "visitorId" => "old#{i}", "events" => [event("o#{i}", "var#{i}")] }
      end

      queue.requeue(drained)

      expect(queue.size).to eq(1000)
      warns = sink.entries.filter_map { |level, message| message if level == :warn }
      expect(warns).to include("VisitorsQueue#enqueue: queue full, dropping oldest event")
      # The oldest requeued events are the ones dropped (drop-oldest), so the
      # most-recent live traffic is retained.
      visitors = queue.drain!
      ids = visitors.map { |v| v["visitorId"] }
      expect(ids).not_to include("old0")
    end
  end

  # Story 4.4: the child-side queue-ownership clear. A forked child inherits a
  # COPY of the parent's queued events; the child must start EMPTY so it never
  # double-delivers the parent's events (the parent's timer still runs there and
  # delivers them). #clear is the atomic, allocation-light empty used by the
  # ApiManager child-callback (drain! would allocate a discarded array).
  describe "#clear (Story 4.4 child queue-ownership)" do
    it "empties the queue and resets size to zero" do
      queue.enqueue("v1", event("e1", "var1"))
      queue.enqueue("v2", event("e2", "var2"))

      queue.clear

      expect(queue.size).to eq(0)
      expect(queue.drain!).to eq([])
    end

    it "is a no-op on an already-empty queue (idempotent)" do
      queue.clear
      queue.clear

      expect(queue.size).to eq(0)
    end
  end
end
