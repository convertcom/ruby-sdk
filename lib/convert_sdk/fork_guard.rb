# frozen_string_literal: true

module ConvertSdk
  # The SDK's single fork-detection authority and the ONLY +Process._fork+
  # prepend in the gem — the SDK's only global mutation (NFR15, architecture
  # Decision 6). It follows the Rails ForkTracker pattern: a module prepended
  # onto +Process.singleton_class+ whose +_fork+ wraps +super+ and, when it
  # returns +0+ (the child), runs the re-arm path. The prepend is installed once
  # at SDK load (it must exist before any fork; installing it is cheap and
  # thread-free, so it does not violate the NFR4 zero-threads-until-use rule —
  # that rule concerns THREADS, not this hook).
  #
  # Fork detection elsewhere uses {.forked?} — a free integer comparison
  # (+Process.pid != owner_pid+, the Datadog idiom) safe to call on every
  # boundary, including JRuby (where it is always false).
  #
  # On JRuby (no +fork+, no +Process._fork+) the prepend is a no-op by
  # construction: {.install!} skips it, so {.forked?} stays false forever.
  #
  # Consumers register their thread-owning timers via {.register_timer} and any
  # child-side cleanup (e.g. ApiManager's queue-ownership clear in Story 4.2) via
  # {.register_child_callback}, keeping ForkGuard decoupled from its callers.
  # {.rearm!} is the shared re-arm path (also invoked by +Client#postfork+ in
  # Epic 4): it marks every registered timer dead, then fires every registered
  # child-callback in registration order, then resets +owner_pid+.
  #
  # The child hook path is LOCK-MINIMAL — mutexes held by other threads at the
  # moment of fork are a classic deadlock source. It resets +owner_pid+ first,
  # then iterates a SNAPSHOT of the timer registry and a SNAPSHOT of the
  # child-callback registry taken under the registry mutex.
  #
  # @api private — not part of the public SDK surface.
  module ForkGuard
    # Thread safety: @registry_mutex guards @timers and @child_callbacks; the
    # singleton-class prepend, @installed flag, @owner_pid, and @logger are
    # module-level state mutated only at install / arm / wiring time.
    @registry_mutex = Thread::Mutex.new
    @timers = []
    @child_callbacks = []
    @installed = false
    @owner_pid = Process.pid
    @logger = nil

    class << self
      # @return [Integer] the pid that currently owns the SDK's threads.
      attr_reader :owner_pid

      # Module-level logger, settable at wiring time (Client wires it in 2.7).
      # nil-safe before wiring — the hook never assumes a logger is present.
      # @return [ConvertSdk::LogManager, nil]
      attr_accessor :logger

      # Install the +Process._fork+ prepend. Idempotent (double-install guarded)
      # and a no-op when fork is unsupported (JRuby) — the prepend never lands,
      # so the hook is a no-op by construction. Safe to call repeatedly.
      # @return [void]
      def install!
        return unless Process.respond_to?(:_fork) && Process.respond_to?(:fork)
        return if @installed

        Process.singleton_class.prepend(ForkHook)
        @installed = true
        @owner_pid = Process.pid
      end

      # @return [Boolean] true iff the current process differs from the owner
      #   (i.e. we are in a forked child). A free comparison; false on JRuby.
      def forked?
        Process.pid != @owner_pid
      end

      # Register a thread-owning timer to be marked dead in a forked child.
      # @param timer [#mark_dead]
      # @return [void]
      def register_timer(timer)
        @registry_mutex.synchronize { @timers << timer }
      end

      # Register a child-side callback fired after timers are marked dead (e.g.
      # queue-ownership clear). Keeps ForkGuard decoupled from its callers.
      # @param callable [#call]
      # @return [void]
      def register_child_callback(callable)
        @registry_mutex.synchronize { @child_callbacks << callable }
      end

      # The shared re-arm path: reset owner_pid, mark every registered timer
      # dead, then fire every child-callback in registration order. Lock-minimal:
      # owner_pid is reset first, then SNAPSHOTS of the registries are iterated
      # outside the registry mutex (deadlock-safe in the fork hook).
      # @return [void]
      def rearm!
        @owner_pid = Process.pid
        timers, callbacks = @registry_mutex.synchronize { [@timers.dup, @child_callbacks.dup] }
        @logger&.debug("ForkGuard#rearm!: fork detected, re-arming #{timers.size} timer(s) in pid #{Process.pid}")
        timers.each(&:mark_dead)
        callbacks.each(&:call)
      end

      # Test-only reap that STOPS (signals exit + joins) every registered timer
      # so NO BackgroundTimer thread can survive into the next example. Distinct
      # from {.reset_for_tests!}, which only clears the registry (it leaves any
      # live thread running). A leaked flush/refresh timer thread firing a real
      # POST/GET after its example ends pollutes a later example's zero-HTTP
      # assertion under WebMock (intermittent on JRuby's thread scheduling) — a
      # global +after(:each)+ reap closes that window deterministically. Iterates
      # a SNAPSHOT taken under the registry mutex; +#stop+ is idempotent so this
      # is a cheap no-op for already-stopped timers.
      # @api private
      # @return [void]
      def stop_all_timers!
        timers = @registry_mutex.synchronize { @timers.dup }
        timers.each(&:stop)
      end

      # Test-only reset so the singleton-state module is order-independent under
      # RSpec. Clears registries, resets owner_pid, drops the logger. Does NOT
      # uninstall the prepend (it is harmless and global).
      # @api private
      # @return [void]
      def reset_for_tests!
        @registry_mutex.synchronize do
          @timers = []
          @child_callbacks = []
        end
        @owner_pid = Process.pid
        @logger = nil
      end
    end

    # The prepended +_fork+ wrapper (Rails ForkTracker pattern). In the child
    # (+super+ returns 0) it runs the shared re-arm path; the parent path is a
    # pass-through.
    # @api private
    module ForkHook
      # @return [Integer] the pid returned by the real +_fork+.
      def _fork
        pid = super
        ForkGuard.rearm! if pid.zero?
        pid
      end
    end
  end
end
