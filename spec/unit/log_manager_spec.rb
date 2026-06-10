# frozen_string_literal: true

require "spec_helper"

# The five public level methods and the sink level each dispatches to.
# trace and debug both land on the sink's #debug (stdlib has no trace).
LOG_METHOD_TO_SINK_LEVEL = {
  trace: :debug,
  debug: :debug,
  info: :info,
  warn: :warn,
  error: :error
}.freeze

# Numeric LogLevel value gating each public method's emission.
LOG_METHOD_TO_VALUE = {
  trace: ConvertSdk::LogLevel::TRACE,
  debug: ConvertSdk::LogLevel::DEBUG,
  info: ConvertSdk::LogLevel::INFO,
  warn: ConvertSdk::LogLevel::WARN,
  error: ConvertSdk::LogLevel::ERROR
}.freeze

RSpec.describe ConvertSdk::LogManager do
  let(:sink) { CapturingSink.new }

  # A manager at TRACE (emits everything) with one capturing sink, no secrets.
  def manager(level: ConvertSdk::LogLevel::TRACE, secrets: [])
    described_class.new(level: level, sink: sink, secrets: secrets)
  end

  describe "#add_sink — duck-type validation" do
    let(:log_manager) { described_class.new(level: ConvertSdk::LogLevel::TRACE) }

    it "accepts any object responding to debug/info/warn/error" do
      log_manager.add_sink(CapturingSink.new)
      expect { log_manager.info("Class#m: hi") }.not_to raise_error
    end

    it "accepts the stdlib Logger" do
      require "logger"
      expect { log_manager.add_sink(Logger.new(File::NULL)) }.not_to raise_error
    end

    it "rejects an object missing a required method without raising" do
      partial = Object.new
      def partial.debug(_msg); end
      def partial.info(_msg); end
      def partial.warn(_msg); end
      # no #error
      expect { log_manager.add_sink(partial) }.not_to raise_error
    end

    it "does not fan out to a rejected sink" do
      rejected = CapturingSink.new
      rejected.singleton_class.undef_method(:error)
      log_manager.add_sink(rejected)
      log_manager.error("Class#m: oops")
      expect(rejected.entries).to be_empty
    end
  end

  describe "multi-sink fan-out" do
    it "emits to every registered sink" do
      second = CapturingSink.new
      mgr = manager
      mgr.add_sink(second)
      mgr.info("Class#m: hello")
      expect(sink.messages).to eq(["Class#m: hello"])
      expect(second.messages).to eq(["Class#m: hello"])
    end
  end

  describe "level dispatch (trace/debug -> sink #debug)" do
    LOG_METHOD_TO_SINK_LEVEL.each do |method, sink_level|
      it "##{method} dispatches to sink ##{sink_level}" do
        manager.public_send(method, "C#m: x")
        expect(sink.entries).to eq([[sink_level, "C#m: x"]])
      end
    end
  end

  describe "level gating (numeric threshold)" do
    # For each (public method, configured threshold) pair the method emits iff
    # the method's value is >= the threshold. 5 methods x 6 thresholds.
    LOG_METHOD_TO_VALUE.each do |method, method_value|
      (ConvertSdk::LogLevel::TRACE..ConvertSdk::LogLevel::SILENT).each do |threshold|
        should_emit = method_value >= threshold
        it "##{method} #{should_emit ? "emits" : "suppressed"} at threshold #{threshold}" do
          manager(level: threshold).public_send(method, "C#m: msg")
          expect(sink.entries.empty?).to be(!should_emit)
        end
      end
    end

    it "SILENT suppresses even error" do
      manager(level: ConvertSdk::LogLevel::SILENT).error("C#m: critical")
      expect(sink.entries).to be_empty
    end
  end

  describe "sink-failure containment" do
    it "swallows a raising sink and still reaches healthy sinks" do
      mgr = manager
      mgr.add_sink(RaisingSink.new)
      healthy = CapturingSink.new
      mgr.add_sink(healthy)
      expect { mgr.info("C#m: keep going") }.not_to raise_error
      expect(healthy.messages).to eq(["C#m: keep going"])
    end
  end

  describe "loggable conversion boundary" do
    it "serializes a hash to a compact string (no raw dump bypass)" do
      manager.info({ status: "ok", count: 2 })
      expect(sink.messages.first).to be_a(String)
      expect(sink.messages.first).to include("status").and include("ok")
    end

    it "serializes an array argument to a string" do
      manager.info([1, 2, 3])
      expect(sink.messages.first).to be_a(String)
    end

    it "passes a string message through unchanged in structure" do
      manager.info("C#m: plain")
      expect(sink.messages.first).to eq("C#m: plain")
    end
  end

  describe "redaction is unbypassable" do
    let(:secret) { "sdkkeysecret12345" }
    let(:mgr) { manager(secrets: [secret]) }

    # Every public log method, with a secret-bearing message AND a secret in a
    # URL query. None may leak the raw secret to the sink.
    LOG_METHOD_TO_VALUE.each_key do |method|
      it "##{method} never emits the raw secret" do
        mgr.public_send(method, "C#m: key=#{secret} at https://h/p?token=#{secret}")
        expect(sink.joined).not_to include(secret)
      end
    end

    it "leaks zero raw secrets across a full multi-call sequence" do
      mgr.register_secret("anothersecret999")
      mgr.trace("C#m: t #{secret}")
      mgr.debug("C#m: d https://h/a?k=#{secret}")
      mgr.info("C#m: i anothersecret999")
      mgr.warn("C#m: w #{secret}/anothersecret999")
      mgr.error("C#m: e https://h/b?x=anothersecret999")
      expect(sink.joined).not_to include(secret)
      expect(sink.joined).not_to include("anothersecret999")
    end

    it "masks a secret registered after construction" do
      mgr.register_secret("latesecret888")
      mgr.info("C#m: v=latesecret888")
      expect(sink.joined).not_to include("latesecret888")
    end
  end

  describe "thread-safe snapshot iteration (concurrency smoke)" do
    it "registers sinks from threads while emitting without error" do
      mgr = described_class.new(level: ConvertSdk::LogLevel::TRACE)
      errors = []
      threads = Array.new(8) do |i|
        Thread.new do
          mgr.add_sink(CapturingSink.new)
          mgr.info("C#m: concurrent #{i}")
        rescue StandardError => e
          errors << e
        end
      end
      threads.each(&:join)
      expect(errors).to be_empty
    end
  end
end
