# frozen_string_literal: true

require "spec_helper"

# A controllable monotonic clock for deterministic TTL math (no real sleeps).
class StubClock
  def initialize(now = 5000.0)
    @now = now
  end

  def call
    @now
  end

  def advance(seconds)
    @now += seconds
  end
end

RSpec.describe ConvertSdk::DataManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) do
    ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
  end
  let(:manager) { described_class.new(log_manager: log_manager) }

  # The vendored config envelope (string keys, exactly the wire shape).
  let(:config) do
    JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__)))
  end
  let(:data) { config["data"] }

  # A manager with the vendored config already installed.
  def installed
    described_class.new(log_manager: log_manager).tap { |m| m.install_config(config) }
  end

  describe "#config_available?" do
    it "is false before any config is installed" do
      expect(manager.config_available?).to be(false)
    end

    it "is true once a config is installed" do
      expect(installed.config_available?).to be(true)
    end
  end

  describe "readers before config is installed (nil-safe)" do
    it "returns nil for scalar readers" do
      expect(manager.account_id).to be_nil
      expect(manager.project_id).to be_nil
    end

    %i[experiences features goals audiences segments locations].each do |reader|
      it "returns an empty array for the #{reader} collection reader" do
        expect(manager.public_send(reader)).to eq([])
      end
    end

    it "returns nil for by-key lookups" do
      expect(manager.experience_by_key("anything")).to be_nil
      expect(manager.feature_by_key("anything")).to be_nil
      expect(manager.goal_by_key("anything")).to be_nil
    end
  end

  describe "#install_config — first/updated/rejected marker" do
    it "returns :first on the first successful install" do
      expect(manager.install_config(config)).to eq(:first)
    end

    it "returns :updated on every subsequent install" do
      manager.install_config(config)
      expect(manager.install_config(config)).to eq(:updated)
    end

    it "returns false and keeps the prior snapshot when given a non-Hash" do
      manager.install_config(config)
      expect(manager.install_config("nope")).to be(false)
      expect(manager.config_available?).to be(true)
      expect(sink.entries.map(&:first)).to include(:warn)
    end
  end

  describe "#install_config — deep-frozen snapshot (AC#3)" do
    it "deep-freezes every nested Hash/Array/String node" do
      manager.install_config(config)
      snapshot = manager.experiences
      expect(DeepFrozen.unfrozen_nodes(snapshot)).to eq([])
    end

    it "freezes the top-level snapshot itself" do
      manager.install_config(config)
      expect(manager.experiences).to be_frozen
      expect(manager.experiences.first).to be_frozen
    end

    it "does not mutate the caller's input hash (defensive copy via frozen install)" do
      manager.install_config(config)
      # The caller's source object remains usable; readers expose frozen copies.
      expect(config).not_to be_frozen
    end
  end

  describe "scalar readers against the fixture" do
    it "exposes account_id from data.account_id" do
      expect(installed.account_id).to eq(data["account_id"])
    end

    it "exposes project_id from data.project.id" do
      expect(installed.project_id).to eq(data["project"]["id"])
    end

    it "exposes the project sub-hash frozen" do
      project = installed.project
      expect(project["id"]).to eq("10025986")
      expect(project).to be_frozen
    end
  end

  describe "collection readers against the fixture (tabular)" do
    # reader => the fixture key under data it mirrors.
    {
      experiences: "experiences",
      features: "features",
      goals: "goals",
      audiences: "audiences",
      segments: "segments"
    }.each do |reader, key|
      it "#{reader} returns the frozen data['#{key}'] array" do
        result = installed.public_send(reader)
        expect(result).to eq(data[key])
        expect(result).to be_frozen
      end
    end

    it "locations returns an empty array when the key is absent in the config" do
      expect(installed.locations).to eq([])
    end
  end

  describe "by-key readers against the fixture (tabular)" do
    {
      experience_by_key: %w[experiences test-experience-ab-fullstack-2 100218245],
      feature_by_key: %w[features feature-1 10024],
      goal_by_key: %w[goals increase-engagement 100215960]
    }.each do |reader, (_key, lookup, expected_id)|
      it "#{reader} finds the entity by its key and returns a frozen hash" do
        entity = installed.public_send(reader, lookup)
        expect(entity["id"]).to eq(expected_id)
        expect(entity).to be_frozen
      end
    end

    it "by-key readers return nil for an unknown key" do
      expect(installed.experience_by_key("nope")).to be_nil
      expect(installed.feature_by_key("nope")).to be_nil
      expect(installed.goal_by_key("nope")).to be_nil
    end
  end

  describe "atomic swap behind the config mutex (AC#3)" do
    it "never exposes a torn or nil snapshot to a concurrent reader during install" do
      manager.install_config(config)
      stop = false
      started = Queue.new
      observed = [] #: Array[untyped]
      reader = Thread.new do
        started << :ok
        observed << manager.experiences until stop
      end

      started.pop # ensure the reader thread is running before installs begin
      200.times { manager.install_config(config) }
      stop = true
      reader.join

      # Every observed snapshot is a complete, frozen array — never nil, never
      # partially-built. Frozen-by-identity makes a torn read impossible.
      expect(observed).not_to be_empty
      observed.each do |snapshot|
        expect(snapshot).to be_a(Array)
        expect(snapshot).to be_frozen
        expect(snapshot.size).to eq(data["experiences"].size)
      end
    end
  end

  # --- Story 2.7: cache write + TTL bookkeeping ------------------------------

  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:dsm) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:cache_key) { dsm.config_key("sdk-key-1") }
  let(:clock) { StubClock.new }

  # A DataManager wired with the cache + TTL surface (Story 2.7). Timer-off mode
  # is derived from a nil ttl (matching the production wiring), so a nil ttl both
  # enables the decision-time check and uses the default 300s staleness window.
  def caching_manager(ttl: 300, refetch: nil)
    described_class.new(
      log_manager: log_manager, data_store_manager: dsm, config_key: cache_key,
      ttl: ttl, clock: clock, refetch: refetch
    )
  end

  describe "#install_config — config cache write (Story 2.7 AC#1)" do
    it "writes the config under the byte-exact key with a wall-clock fetched_at" do
      caching_manager.install_config(config)
      entry = store.get(cache_key)
      expect(entry["config"]).to eq(config)
      expect(entry["fetched_at"]).to be_a(Float)
    end

    it "does not write to a store when no data_store_manager is wired" do
      manager.install_config(config)
      expect(store.get(cache_key)).to be_nil
    end
  end

  describe "#config_stale? (monotonic TTL)" do
    it "is false right after install and true once the ttl elapses" do
      m = caching_manager(ttl: 300)
      m.install_config(config)
      expect(m.config_stale?).to be(false)
      clock.advance(301)
      expect(m.config_stale?).to be(true)
    end

    it "is false before any config is installed" do
      expect(caching_manager.config_stale?).to be(false)
    end

    it "uses the default 300s TTL in timer-off mode (ttl nil)" do
      m = caching_manager(ttl: nil)
      m.install_config(config)
      clock.advance(ConvertSdk::DEFAULT_CONFIG_TTL - 1)
      expect(m.config_stale?).to be(false)
      clock.advance(2)
      expect(m.config_stale?).to be(true)
    end
  end

  describe "#install_from_cache_if_fresh" do
    it "installs a non-stale cached entry and returns the :first marker" do
      store.set(cache_key, { "config" => config, "fetched_at" => Time.now.to_f })
      m = caching_manager
      expect(m.install_from_cache_if_fresh).to eq(:first)
      expect(m.account_id).to eq("10022898")
    end

    it "ignores a stale cached entry" do
      store.set(cache_key, { "config" => config, "fetched_at" => Time.now.to_f - 1000 })
      expect(caching_manager(ttl: 300).install_from_cache_if_fresh).to be_nil
    end

    it "ignores an absent or malformed cached entry" do
      expect(caching_manager.install_from_cache_if_fresh).to be_nil
      store.set(cache_key, { "config" => "not-a-hash", "fetched_at" => Time.now.to_f })
      expect(caching_manager.install_from_cache_if_fresh).to be_nil
    end
  end

  describe "#ensure_fresh_config! (timer-off decision-time check)" do
    it "is a no-op when the timer is enabled (ttl present)" do
      called = 0
      m = caching_manager(ttl: 300, refetch: -> { called += 1 })
      m.install_config(config)
      clock.advance(1000)
      m.ensure_fresh_config!
      expect(called).to eq(0)
    end

    it "is a no-op when no refetch callable is wired" do
      m = caching_manager(ttl: nil, refetch: nil)
      m.install_config(config)
      clock.advance(1000)
      expect { m.ensure_fresh_config! }.not_to raise_error
    end

    it "invokes the refetch callable once when stale (timer-off)" do
      called = 0
      m = caching_manager(ttl: nil, refetch: -> { called += 1 })
      m.install_config(config)
      clock.advance(1000)
      m.ensure_fresh_config!
      expect(called).to eq(1)
    end

    it "does not refetch when the config is still fresh" do
      called = 0
      m = caching_manager(ttl: nil, refetch: -> { called += 1 })
      m.install_config(config)
      m.ensure_fresh_config!
      expect(called).to eq(0)
    end
  end
end
