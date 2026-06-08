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

  # --- Story 4.3: conversion tracking + two-level atomic goal dedup ----------

  # A DataManager wired with the live store + config + key resolvers so #convert
  # can read goals, persist the goals-map mark atomically, and read the stored
  # bucketing map for bucketingData. Single construction site for the section.
  def converting_manager
    described_class.new(
      log_manager: log_manager, data_store_manager: dsm,
      account_resolver: -> { data["account_id"] },
      project_resolver: -> { data["project"]["id"] }
    ).tap { |m| m.install_config(config) }
  end

  let(:conv_visitor) { "visitor-conv" }
  let(:goal_key) { "increase-engagement" }
  let(:goal_id) { "100215960" }
  let(:store_key) { dsm.visitor_key(data["account_id"], data["project"]["id"], conv_visitor) }

  # The persisted goals map for the conversion visitor (or {} when none).
  def stored_goals(manager_unused = nil)
    (store.get(store_key) || {})["goals"] || {}
  end

  describe "#convert — goal lookup + enqueue contract (AC#1)" do
    it "returns the conversion data hash for a fresh goal" do
      result = converting_manager.convert(conv_visitor, goal_key)
      expect(result).to include("goalId" => goal_id)
    end

    it "omits goalData when none is supplied" do
      result = converting_manager.convert(conv_visitor, goal_key)
      expect(result).not_to have_key("goalData")
    end

    it "returns nil and debug-logs on an unknown goal key (miss → no enqueue)" do
      result = converting_manager.convert(conv_visitor, "no-such-goal")
      expect(result).to be_nil
      expect(sink.messages.any? { |l| l.include?("convert") && l.include?("no goal") }).to be(true)
    end
  end

  describe "#convert — goalData 8-key validation → [{key,value}] pairs (AC#1)" do
    # Each platform key, supplied via its snake_case Ruby kwarg-symbol form,
    # must surface as the camelCase wire identifier in a {key,value} pair.
    {
      amount: "amount",
      products_count: "productsCount",
      transaction_id: "transactionId",
      custom_dimension_1: "customDimension1",
      custom_dimension_2: "customDimension2",
      custom_dimension_3: "customDimension3",
      custom_dimension_4: "customDimension4",
      custom_dimension_5: "customDimension5"
    }.each do |ruby_key, wire_key|
      it "maps #{ruby_key} → #{wire_key} as a {key,value} pair" do
        result = converting_manager.convert(conv_visitor, goal_key, goal_data: { ruby_key => 7 })
        expect(result["goalData"]).to eq([{ "key" => wire_key, "value" => 7 }])
      end
    end

    it "emits goalData as an array of pairs, not a flat map" do
      result = converting_manager.convert(
        conv_visitor, goal_key, goal_data: { amount: 49.99, transaction_id: "tx-1" }
      )
      expect(result["goalData"]).to contain_exactly(
        { "key" => "amount", "value" => 49.99 },
        { "key" => "transactionId", "value" => "tx-1" }
      )
    end

    it "rejects unknown goalData keys and debug-logs" do
      result = converting_manager.convert(conv_visitor, goal_key, goal_data: { bogus: 1, amount: 5 })
      keys = result["goalData"].map { |pair| pair["key"] }
      expect(keys).to eq(["amount"])
      expect(sink.messages.any? { |l| l.include?("convert") && l.include?("bogus") }).to be(true)
    end
  end

  describe "#convert — two-level atomic dedup (AC#2)" do
    it "marks the goal in the visitor's StoreData goals map on first conversion" do
      converting_manager.convert(conv_visitor, goal_key)
      expect(stored_goals[goal_id]).to be_truthy
    end

    it "deduplicates a repeat conversion for the same goal (nil, no second enqueue)" do
      m = converting_manager
      expect(m.convert(conv_visitor, goal_key)).not_to be_nil
      expect(m.convert(conv_visitor, goal_key)).to be_nil
    end

    it "debug-logs the dedup skip" do
      m = converting_manager
      m.convert(conv_visitor, goal_key)
      m.convert(conv_visitor, goal_key)
      expect(sink.messages.any? { |l| l.include?("convert") && l.include?("already") }).to be(true)
    end

    it "tracks distinct goals independently for the same visitor" do
      m = converting_manager
      expect(m.convert(conv_visitor, goal_key)).not_to be_nil
      expect(m.convert(conv_visitor, "decrease-bounce-rate")).not_to be_nil
    end

    it "tracks the same goal independently for distinct visitors (visitor in the key)" do
      m = converting_manager
      expect(m.convert("vis-a", goal_key)).not_to be_nil
      expect(m.convert("vis-b", goal_key)).not_to be_nil
    end

    # THE qs-01 regression: N threads racing the SAME visitor+goal must produce
    # EXACTLY ONE non-nil result (one enqueue). The check-then-mark is one locked
    # op inside the store merge mutex, so the race cannot double-count.
    it "enqueues EXACTLY ONE conversion under N concurrent same-goal tracks (qs-01)" do
      m = converting_manager
      thread_count = 25
      barrier = Thread::Queue.new
      results = Array.new(thread_count)
      threads = (0...thread_count).map do |i|
        Thread.new do
          barrier.pop
          results[i] = m.convert(conv_visitor, goal_key)
        end
      end
      thread_count.times { barrier.push(:go) }
      threads.each(&:join)
      enqueued = results.compact
      expect(enqueued.size).to eq(1)
      expect(stored_goals[goal_id]).to be_truthy
    end
  end

  describe "#convert — force_multiple_transactions bypass (AC#3)" do
    it "bypasses dedup and still returns a conversion on a duplicate" do
      m = converting_manager
      m.convert(conv_visitor, goal_key)
      result = m.convert(conv_visitor, goal_key, force_multiple_transactions: true)
      expect(result).to include("goalId" => goal_id)
    end

    it "enqueues a fresh forced conversion even with no prior mark" do
      result = converting_manager.convert(conv_visitor, goal_key, force_multiple_transactions: true)
      expect(result).to include("goalId" => goal_id)
    end

    it "does NOT re-mark on force when there was no prior mark (conservative default)" do
      m = converting_manager
      m.convert(conv_visitor, goal_key, force_multiple_transactions: true)
      expect(stored_goals).not_to have_key(goal_id)
    end

    it "preserves (does not corrupt) a prior mark when forcing" do
      m = converting_manager
      m.convert(conv_visitor, goal_key) # marks
      m.convert(conv_visitor, goal_key, force_multiple_transactions: true) # bypass, no re-mark
      # A subsequent non-forced call still sees the original mark → deduplicated.
      expect(m.convert(conv_visitor, goal_key)).to be_nil
    end
  end

  describe "#convert — bucketingData attribution (AC#4)" do
    it "includes the stored bucketing map as bucketingData for a bucketed visitor" do
      dsm.merge_visitor_data(data["account_id"], data["project"]["id"], conv_visitor) do |_c|
        { "bucketing" => { "100" => "200", "101" => "201" } }
      end
      result = converting_manager.convert(conv_visitor, goal_key)
      expect(result["bucketingData"]).to eq({ "100" => "200", "101" => "201" })
    end

    it "omits bucketingData for an unbucketed visitor (empty stored map)" do
      result = converting_manager.convert(conv_visitor, goal_key)
      expect(result).not_to have_key("bucketingData")
    end
  end
end
