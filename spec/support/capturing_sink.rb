# frozen_string_literal: true

# A stdlib-Logger-compatible test sink that captures every emitted message.
#
# Duck-typed to +debug/info/warn/error+ so it is accepted by
# +ConvertSdk::LogManager#add_sink+. Records each call as a +[level, message]+
# pair so specs can assert on fan-out, level dispatch, and — critically — that
# no raw secret ever reaches a sink.
#
# Reused by Story 4.7's full-lifecycle TRACE capture gate, so it lives in
# +spec/support/+ rather than inline in a single spec.
class CapturingSink
  # @return [Array<Array(Symbol, String)>] captured [level, message] pairs.
  attr_reader :entries

  def initialize
    @entries = []
  end

  %i[debug info warn error].each do |level|
    define_method(level) do |message|
      @entries << [level, message.to_s]
    end
  end

  # @return [Array<String>] just the captured message strings.
  def messages
    @entries.map(&:last)
  end

  # @return [String] all captured messages joined — convenient for a single
  #   "contains no raw secret" assertion across a multi-call sequence.
  def joined
    messages.join("\n")
  end
end

# A sink that raises on every call — proves LogManager contains sink failures
# (a broken sink must never crash the host or starve other sinks).
class RaisingSink
  %i[debug info warn error].each do |level|
    define_method(level) do |_message|
      raise StandardError, "sink boom (#{level})"
    end
  end
end
