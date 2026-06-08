# frozen_string_literal: true

module ConvertSdk
  # The per-visitor event queue — the in-memory buffer between the decision flow
  # (which enqueues bucketing/conversion events) and {ApiManager} (which drains
  # and POSTs them in the Convert wire format).
  #
  # == Per-visitor merge (structural invariant, FR36)
  #
  # The queue holds ONE entry per visitor — a string-keyed wire-shaped hash
  # +{"visitorId" => id, "segments" => {...}?, "events" => [...]}+. Enqueuing an
  # event for a visitor already in the queue APPENDS to that visitor's +events+
  # array; it never adds a duplicate visitor entry and never flattens to a bare
  # event list. The platform attributes events by walking +visitors[].events+, so
  # flattening or duplicating corrupts report attribution. The structure itself
  # enforces the invariant — there is no public path that bypasses the merge.
  # (JS parity: +api-manager.ts:117-144+; PHP +VisitorsQueue.php:64-70+.)
  #
  # +segments+ ride on the visitor entry and are captured ONLY when the entry is
  # first created (omitted entirely when none are supplied) — a later enqueue for
  # the same visitor never overwrites them (JS +if (segments) visitor.segments = …+).
  #
  # == Bounded memory (FR39/NFR10)
  #
  # The queue is bounded at {MAX_EVENTS} EVENTS (events, not visitors). On
  # overflow the OLDEST event is dropped — and the visitor entry is removed once
  # its last event is gone — with a +warn+ log per drop. An endpoint outage can
  # never grow host memory without bound; dropping the oldest (not the newest)
  # keeps the most recent traffic. (Optimizely +DEFAULT_QUEUE_CAPACITY = 1000+
  # precedent; research frozen register #7.)
  #
  # == Thread safety (NFR2/NFR13)
  #
  # Every operation is serialized by +@queue_mutex+. {#enqueue} is pure in-memory
  # and never blocks on I/O, so the calling request thread is never held on the
  # network. {#drain!} is an atomic drain-and-swap inside the lock returning the
  # drained visitors array — {ApiManager} builds the payload and POSTs OUTSIDE the
  # lock, so network I/O never holds the queue. The drained array is re-enqueueable
  # without violating the per-visitor merge (the retention path Story 4.2 needs).
  #
  # @api private
  class VisitorsQueue
    # The hard upper bound on buffered events (events, not visitors). Research
    # frozen register #7; the JS SDK has no equivalent memory cap.
    MAX_EVENTS = 1000

    # @param log_manager [LogManager] the redacting logging surface (warn on overflow).
    def initialize(log_manager:)
      @log_manager = log_manager
      # Thread safety: guarded by @queue_mutex. @items is the ordered list of
      # per-visitor entries; @size is the total event count (the cap dimension).
      @queue_mutex = Thread::Mutex.new
      @items = [] #: Array[Hash[String, untyped]]
      @size = 0
    end

    # Enqueue one wire-shaped event for +visitor_id+, merging into the visitor's
    # existing entry (append) or creating a new one. Pure in-memory — never blocks
    # on I/O. On overflow past {MAX_EVENTS} the oldest event is dropped (+warn+).
    #
    # @param visitor_id [String] the visitor the event belongs to.
    # @param event [Hash{String=>Object}] a wire-shaped (string-keyed camelCase)
    #   event hash, e.g. +{"eventType"=>"bucketing", "data"=>{...}}+.
    # @param segments [Hash{String=>Object}, nil] the visitor's report-segments,
    #   attached ONLY when this enqueue first creates the visitor's entry.
    # @return [void]
    def enqueue(visitor_id, event, segments: nil)
      @queue_mutex.synchronize do
        entry = @items.find { |item| item["visitorId"] == visitor_id }
        if entry
          entry["events"] << event
        else
          entry = { "visitorId" => visitor_id, "events" => [event] } #: Hash[String, untyped]
          entry["segments"] = segments unless segments.nil?
          @items << entry
        end
        @size += 1
        trim_to_cap
      end
    end

    # Atomically drain the queue: swap out the current per-visitor entries and
    # reset to empty inside the lock, returning the drained array. The caller
    # (ApiManager) builds the payload and POSTs OUTSIDE the lock.
    #
    # @return [Array<Hash{String=>Object}>] the drained per-visitor entries
    #   (empty when nothing was queued); re-enqueueable verbatim.
    def drain!
      @queue_mutex.synchronize do
        drained = @items
        @items = []
        @size = 0
        drained
      end
    end

    # Re-enqueue previously drained per-visitor entries after a failed delivery
    # (Story 4.2 failure retention), PRESERVING the per-visitor merge. Runs as one
    # atomic compound operation inside +@queue_mutex+.
    #
    # The drained events are OLDER than anything the queue received during the
    # failed POST, so they are placed BEFORE newer events: a drained visitor that
    # already has a live entry (new events arrived for it mid-failure) has its
    # drained events PREPENDED to that entry — never a duplicate visitor entry;
    # a drained visitor with no live entry is inserted at the FRONT of the queue
    # (its events are the oldest). Segments ride from whichever entry has them
    # (the live entry wins; otherwise the drained entry's segments are adopted).
    #
    # Re-enqueued events count toward {MAX_EVENTS}: a sustained outage that keeps
    # requeuing drops the OLDEST events (+warn+ per drop), bounding host memory
    # without bound (NFR10).
    #
    # @param visitors [Array<Hash{String=>Object}>] drained per-visitor entries
    #   (as returned by {#drain!}); an empty array is a no-op.
    # @return [void]
    def requeue(visitors)
      return if visitors.empty?

      @queue_mutex.synchronize do
        # Walk the drained entries in reverse so that successive front-inserts
        # preserve their original relative order at the head of the queue.
        visitors.reverse_each { |drained| merge_drained(drained) }
        trim_to_cap
      end
    end

    # @return [Integer] the total number of buffered EVENTS (not visitors).
    def size
      @queue_mutex.synchronize { @size }
    end

    private

    # Merge ONE drained per-visitor entry back into @items, preserving the
    # per-visitor merge. Caller holds @queue_mutex.
    #
    # When a live entry exists for the visitor, the drained (older) events are
    # PREPENDED to it and the live entry adopts the drained segments only if it
    # has none. Otherwise the drained entry is inserted at the FRONT of the queue
    # (its events are older than all live traffic). @size grows by the drained
    # event count; {#trim_to_cap} (run by the caller after all merges) bounds it.
    def merge_drained(drained)
      visitor_id = drained["visitorId"]
      drained_events = drained["events"]
      existing = @items.find { |item| item["visitorId"] == visitor_id }
      if existing
        existing["events"].unshift(*drained_events)
        existing["segments"] = drained["segments"] if !existing.key?("segments") && drained.key?("segments")
      else
        @items.unshift(drained)
      end
      @size += drained_events.size
    end

    # Drop oldest events until the event count is within {MAX_EVENTS}. Removes a
    # visitor entry once its last event is gone. Caller holds @queue_mutex.
    def trim_to_cap
      while @size > MAX_EVENTS
        oldest = @items.first
        break if oldest.nil?

        oldest["events"].shift
        @items.shift if oldest["events"].empty?
        @size -= 1
        @log_manager.warn("VisitorsQueue#enqueue: queue full, dropping oldest event")
      end
    end
  end
end
