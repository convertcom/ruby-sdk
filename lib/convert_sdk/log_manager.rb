# frozen_string_literal: true

module ConvertSdk
  # Multi-sink, level-gated logger with secret redaction wired in by
  # construction.
  #
  # +LogManager+ is consumed by every manager from the HTTP client (Story 1.5)
  # onward. It fans messages out to any number of stdlib-+Logger+-compatible
  # *sinks* and guarantees, structurally, that no message reaches a sink
  # without first passing through the {Redactor}: every public level method
  # funnels through the single private +#emit+ path, and that path applies the
  # +loggable+ conversion boundary and redaction before touching a sink. There
  # is no public method that bypasses +#emit+.
  #
  # == Levels
  #
  # Verbosity is gated by the JS-parity {LogLevel} values (TRACE=0 … SILENT=5).
  # A call at level +L+ emits only when +L >= configured_level+; +SILENT+
  # suppresses everything. The stdlib +Logger+ has no +trace+, so both
  # {#trace} and {#debug} dispatch to the sink's +#debug+ — the numeric level
  # value (0 vs 1), not the sink method, decides whether they emit.
  #
  # Level conventions (callers choose the level by intent):
  #
  # * +trace+ / +debug+ — decisioning internals (bucketing, rule evaluation).
  # * +info+  — lifecycle events (SDK ready, config refreshed).
  # * +warn+  — recoverable conditions (stale config, retry).
  # * +error+ — internal failures (parse error, exhausted retries).
  #
  # == Message format
  #
  # Callers pass messages already formatted as <tt>{ClassName}#{method}:
  # {message}</tt>. +LogManager+ does not prepend the class name itself — the
  # format is a usage convention, documented here and enforced at call sites.
  #
  # == Thread safety
  #
  # The sink list is guarded by +@sinks_mutex+. Compound operations on the list
  # happen inside the lock; the (potentially slow, potentially raising) sink
  # I/O happens outside the lock by iterating a +dup+ snapshot. A sink that
  # raises is contained (rescue +StandardError+) so a broken sink never crashes
  # the host or starves the other sinks.
  class LogManager
    # @param level [Integer] a {LogLevel} threshold; messages below it are
    #   suppressed. Defaults to ERROR (quiet by default).
    # @param sink [Object, nil] an optional initial sink (anything responding
    #   to debug/info/warn/error). Invalid sinks are rejected, not raised.
    # @param secrets [Array<String>] secret values to redact from every
    #   message. More can be added later via {#register_secret}.
    def initialize(level: LogLevel::ERROR, sink: nil, secrets: [])
      @level = level
      @redactor = Redactor.new(secrets)
      @sinks = []
      # Thread safety: guarded by @sinks_mutex.
      @sinks_mutex = Thread::Mutex.new
      add_sink(sink) unless sink.nil?
    end

    # The methods every valid sink must respond to (stdlib +Logger+ contract).
    REQUIRED_SINK_METHODS = %i[debug info warn error].freeze

    # Register a sink. Accepted iff it duck-types to the stdlib +Logger+
    # contract (responds to debug/info/warn/error). An invalid sink is rejected
    # with a logged error rather than raising — registration must never crash
    # the host.
    #
    # @param sink [Object] the candidate sink.
    # @return [self] for chaining. A rejected sink is logged, not registered.
    def add_sink(sink)
      if REQUIRED_SINK_METHODS.all? { |m| sink.respond_to?(m) }
        @sinks_mutex.synchronize { @sinks << sink }
      else
        emit(LogLevel::ERROR, "LogManager#add_sink: rejected sink #{sink.class} " \
                              "(must respond to #{REQUIRED_SINK_METHODS.join("/")})")
      end
      self
    end

    # Register an additional secret to redact (e.g. once the SDK key is known
    # at +ConvertSdk.create+ time). nil/blank is a no-op.
    #
    # @param secret [String, nil]
    # @return [void]
    def register_secret(secret)
      @redactor.register_secret(secret)
    end

    # @!method trace(message)
    #   Log at TRACE — decisioning internals. Dispatches to sink +#debug+.
    # @!method debug(message)
    #   Log at DEBUG — decisioning internals. Dispatches to sink +#debug+.
    # @!method info(message)
    #   Log at INFO — lifecycle events.
    # @!method warn(message)
    #   Log at WARN — recoverable conditions.
    # @!method error(message)
    #   Log at ERROR — internal failures.

    def trace(message)
      emit(LogLevel::TRACE, message)
    end

    def debug(message)
      emit(LogLevel::DEBUG, message)
    end

    def info(message)
      emit(LogLevel::INFO, message)
    end

    def warn(message)
      emit(LogLevel::WARN, message)
    end

    def error(message)
      emit(LogLevel::ERROR, message)
    end

    private

    # The single emission funnel. Every public log path lands here. Gates on
    # level, converts the argument across the +loggable+ boundary, redacts the
    # result, then fans out to a snapshot of the sinks. No sink is touched with
    # an unredacted string, and no sink failure escapes.
    def emit(level, message)
      return if level < @level

      text = @redactor.redact(loggable(message))
      sink_method = sink_method_for(level)
      each_sink do |sink|
        sink.public_send(sink_method, text)
      rescue StandardError
        # A broken sink must never crash the host or starve other sinks.
      end
    end

    # The +loggable+ conversion boundary (PHP qs-12 lesson): structured objects
    # become a controlled string BEFORE redaction, since redaction operates on
    # strings. Strings pass through unchanged; everything else is rendered with
    # a compact +#inspect+ so a later raw-object dump cannot bypass redaction.
    def loggable(message)
      return message if message.is_a?(String)

      message.inspect
    end

    # Map a {LogLevel} value to the sink method that carries it. TRACE and
    # DEBUG both go to +#debug+ (stdlib has no trace); the rest map 1:1.
    def sink_method_for(level)
      case level
      when LogLevel::TRACE, LogLevel::DEBUG then :debug
      when LogLevel::INFO then :info
      when LogLevel::WARN then :warn
      else :error
      end
    end

    # Iterate a snapshot of the sink list. The +dup+ is taken inside the lock
    # so registration is atomic against iteration; the yielded I/O runs outside
    # the lock so a slow/blocking sink cannot hold the mutex.
    def each_sink(&)
      snapshot = @sinks_mutex.synchronize { @sinks.dup }
      snapshot.each(&)
    end
  end
end
