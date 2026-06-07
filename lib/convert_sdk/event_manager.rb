# frozen_string_literal: true

module ConvertSdk
  # Synchronous, thread-safe pub/sub engine for SDK lifecycle events.
  #
  # +EventManager+ is the single emission point for the SDK's lifecycle signals.
  # Consumers subscribe with {#on} using the cross-SDK-consistent event names
  # ({SystemEvents}); the SDK's internal stages fire those events with {#fire}
  # as wiring lands in later stories (Client +ready+ in 2.5, +config.updated+
  # per refresh in 2.7, +bucketing+ in 2.11/4.1, +conversion+ in 4.3,
  # +api.queue.released+ in 4.2). This story delivers the engine only.
  #
  # == Event names are a wire-parity surface (FR57)
  #
  # Event names are byte-identical to the JS SDK's +SystemEvents+ strings. A
  # {SystemEvents} constant *is* its wire string (e.g.
  # +SystemEvents::READY == "ready"+), so +on(SystemEvents::READY)+ and
  # +on("ready")+ register under the SAME string key. Names are normalized to
  # their string form (+#to_s+) before they touch the registry.
  #
  # == Synchronous firing
  #
  # Events fire synchronously, in registration order, at each lifecycle stage —
  # no event thread, no queue. A slow listener slows the SDK (documented, JS
  # parity). The firing path never raises into its caller: a listener that
  # raises is caught and logged, and the remaining listeners still run.
  #
  # == Deferred replay for late subscribers
  #
  # Some events (READY, CONVERSION in JS) fire with <tt>deferred: true</tt>. The
  # first deferred emission of an event records its +{payload, err}+ so a
  # listener that subscribes *after* the event already happened is replayed the
  # stored value the moment it registers. This lets late subscribers observe a
  # one-shot lifecycle signal they would otherwise have missed.
  #
  # == Thread safety
  #
  # The listener registry and the deferred store are both guarded by
  # +@listeners_mutex+. Registration mutates the registry inside the lock.
  # Firing takes a +dup+ snapshot of the listener list inside the lock, then
  # iterates that snapshot OUTSIDE the lock — so a listener body (which runs
  # unlocked) may itself call {#on} to register a new listener without
  # deadlocking. The newly added listener is not invoked by the in-flight fire
  # (it was not in the snapshot); it participates in subsequent fires.
  class EventManager
    # @param log_manager [LogManager] sink for contained listener failures and
    #   unknown-event debug traces.
    def initialize(log_manager:)
      @log_manager = log_manager
      # event name (String) => Array<Proc> of listeners, registration-ordered.
      @listeners = {}
      # event name (String) => { payload:, err: } recorded by the first
      # deferred fire, replayed to late subscribers.
      @deferred = {}
      # Thread safety: guarded by @listeners_mutex (both @listeners and @deferred).
      @listeners_mutex = Thread::Mutex.new
    end

    # Subscribe to an event. Public API.
    #
    # Accepts a {SystemEvents} constant (which IS its string value) or any
    # matching string; the name is normalized to its string form so both
    # spellings register under one key. If the event was previously fired with
    # <tt>deferred: true</tt>, the listener is invoked immediately with the
    # stored payload/err (deferred replay).
    #
    # @param event [String] a {SystemEvents} value or matching string.
    # @yieldparam payload [Object, nil] the emitted payload.
    # @yieldparam err [Object, nil] the emitted error, or +nil+ on normal
    #   emission. Single-parameter blocks work — extra args are ignored.
    # @return [self]
    def on(event, &listener)
      return self if listener.nil?

      key = event.to_s
      deferred = @listeners_mutex.synchronize do
        (@listeners[key] ||= []) << listener
        @deferred[key]
      end
      # Replay outside the lock so the listener body may itself call #on.
      invoke(key, listener, deferred[:payload], deferred[:err]) if deferred
      self
    end

    # Emit an event to all currently registered listeners. Internal API.
    #
    # @api private
    # @param event [String] a {SystemEvents} value or matching string.
    # @param payload [Object, nil] delivered as the listener's first argument.
    # @param err [Object, nil] delivered as the listener's second argument
    #   (+nil+ on normal emission).
    # @param deferred [Boolean] when true, the first such emission of this event
    #   is recorded for replay to late subscribers (see class docs).
    # @return [void]
    def fire(event, payload = nil, err = nil, deferred: false)
      key = event.to_s
      snapshot = @listeners_mutex.synchronize do
        @deferred[key] ||= { payload: payload, err: err } if deferred
        @listeners[key]&.dup
      end

      if snapshot.nil? || snapshot.empty?
        @log_manager.debug("EventManager#fire: no listeners for '#{key}'")
        return
      end

      # Iterate the snapshot OUTSIDE the lock — listener bodies run unlocked and
      # may re-register without deadlock.
      snapshot.each { |listener| invoke(key, listener, payload, err) }
    end

    private

    # Invoke one listener with exception containment. A raising listener is
    # caught (StandardError only — never Exception) and logged at error level;
    # it is never re-raised, so siblings still fire and the host never crashes.
    def invoke(event, listener, payload, err)
      listener.call(payload, err)
    rescue StandardError => e
      @log_manager.error(
        "EventManager#fire: listener for '#{event}' raised #{e.class}: #{e.message}"
      )
    end
  end
end
