# frozen_string_literal: true

module ConvertSdk
  # The SDK's single background-thread primitive — the ONLY +Thread.new+ site in
  # the gem (architecture Decision 6, thread/fork boundary). One class, two
  # future instances: the config-refresh timer (Story 2.7) and the queue-flush
  # timer (Story 4.2). It is never subclassed.
  #
  # A timer wraps an +interval+, a tick +block+, and a Mutex'd lifecycle state
  # machine. {#start} lazily spawns a single loop thread (NFR4 — no threads
  # until first use); {#stop} signals it to exit and joins it; {#mark_dead}
  # clears the state WITHOUT joining (the fork re-arm hook — a thread reference
  # copied into a forked child is dead and joining it can hang), so the next
  # {#start} transparently re-arms a fresh thread.
  #
  # The loop sleeps for +interval+ on a {Thread::ConditionVariable} (interruptible
  # — {#stop} is responsive instead of waiting out a bare +sleep+), then runs the
  # block. Each tick is wrapped in +rescue StandardError+ and logged (never
  # +rescue Exception+): a raising tick is logged and the loop continues — an
  # exception must never silently kill a timer thread (never-crash contract).
  #
  # A +nil+ or zero +interval+ is the timer-off mode: {#start} is a guarded
  # no-op and no thread is ever created.
  #
  # @api private — not part of the public SDK surface.
  class BackgroundTimer
    # @param interval [Numeric, nil] seconds between ticks; +nil+/zero disables
    #   the timer (no thread is ever started).
    # @param log_manager [ConvertSdk::LogManager] sink for debug (thread
    #   creation) and error (raising tick) lines.
    # @param name [String] identifies the timer in log lines (e.g. "refresh").
    # @yield the tick block, invoked once per interval.
    def initialize(interval:, log_manager:, name:, &block)
      @interval = interval
      @log_manager = log_manager
      @name = name
      @block = block
      # Thread safety: @thread and @running are guarded by @state_mutex; the
      # condition variable wakes the loop's interruptible sleep on #stop.
      @state_mutex = Thread::Mutex.new
      @sleep_cv = Thread::ConditionVariable.new
      @thread = nil
      @running = false
    end

    # Start the loop thread if not already running. Idempotent: concurrent calls
    # and repeat calls produce exactly one thread. Re-arms transparently after
    # {#mark_dead}. A +nil+/zero interval is a no-op (timer-off mode).
    # @return [void]
    def start
      @state_mutex.synchronize do
        # Timer-off guard: a nil/zero interval never starts (and narrows the
        # interval to a concrete positive Numeric for the loop's sleep).
        interval = @interval
        return if interval.nil? || interval <= 0
        return if @running

        @running = true
        @thread = Thread.new { run_loop(interval.to_f) }
        @log_manager.debug("BackgroundTimer#start: started ##{@name} (interval=#{@interval}s)")
      end
    end

    # Signal the loop to exit and join the thread. Idempotent: a no-op when not
    # running (including after {#mark_dead}).
    # @return [void]
    def stop
      thread = nil #: Thread?
      @state_mutex.synchronize do
        return unless @running

        @running = false
        @sleep_cv.broadcast
        thread = @thread
        @thread = nil
      end
      thread&.join
    end

    # Fork re-arm hook: clear the lifecycle state WITHOUT joining the thread.
    # The thread reference is stale in a forked child (fork copies only the
    # calling thread), so joining it can hang. The next {#start} creates a fresh
    # thread.
    # @return [void]
    def mark_dead
      @state_mutex.synchronize do
        @running = false
        @thread = nil
      end
    end

    # @return [Boolean] whether the loop thread is currently running.
    def alive?
      @state_mutex.synchronize { @running && !@thread.nil? }
    end

    private

    # The loop body. Interruptible-sleeps for +interval+ (a concrete Float), then
    # runs the tick under the never-crash rescue. Exits when +#stop+ clears the
    # +running+ flag.
    # @param interval [Float] validated sleep duration.
    def run_loop(interval)
      loop do
        @state_mutex.synchronize do
          break unless @running

          @sleep_cv.wait(@state_mutex, interval)
        end
        break unless running?

        tick
      end
    end

    # @return [Boolean] a locked read of the running flag.
    def running?
      @state_mutex.synchronize { @running }
    end

    # Run the tick block under the never-crash contract: rescue StandardError,
    # log, and let the loop continue. Never rescue Exception.
    def tick
      @block&.call
    rescue StandardError => e
      @log_manager.error("BackgroundTimer##{@name}: tick raised #{e.class}: #{e.message}")
    end
  end
end
