# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::DataStoreManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }

  # A minimal duck-typed store used to assert passthrough / validation without
  # depending on MemoryStore internals.
  def build_store(getter:, setter:)
    Class.new do
      define_method(:get, &getter) if getter
      define_method(:set, &setter) if setter
    end.new
  end

  describe "store validation at wiring time (AC#1)" do
    # Tabular: each row is a candidate store and whether it should be accepted.
    # "wrong arity" is accepted because the JS contract checks only for the
    # presence of get/set (typeof === 'function'), never arity.
    valid_custom = Object.new
    def valid_custom.get(_key) = nil
    def valid_custom.set(_key, _value) = nil

    missing_get = Object.new
    def missing_get.set(_key, _value) = nil

    missing_set = Object.new
    def missing_set.get(_key) = nil

    wrong_arity = Object.new
    def wrong_arity.get = nil
    def wrong_arity.set(*) = nil

    [
      ["a valid custom store", valid_custom, true],
      ["a store missing #get", missing_get, false],
      ["a store missing #set", missing_set, false],
      ["a store with wrong arity (still accepted, no arity check)", wrong_arity, true]
    ].each do |desc, candidate, accepted|
      it "#{accepted ? 'accepts' : 'rejects'} #{desc}" do
        manager = described_class.new(store: candidate, log_manager: log_manager)
        if accepted
          expect(manager.store).to be(candidate)
        else
          expect(manager.store).to be_a(ConvertSdk::Stores::MemoryStore)
        end
      end
    end

    it "logs an error and falls back to MemoryStore on an invalid store" do
      manager = described_class.new(store: Object.new, log_manager: log_manager)
      expect(manager.store).to be_a(ConvertSdk::Stores::MemoryStore)
      expect(sink.joined).to include("DataStoreManager")
      expect(sink.entries.map(&:first)).to include(:error)
    end

    it "defaults to a MemoryStore when no store is supplied" do
      manager = described_class.new(log_manager: log_manager)
      expect(manager.store).to be_a(ConvertSdk::Stores::MemoryStore)
    end
  end

  describe "passthrough with never-crash rescue (AC#1)" do
    it "returns nil and logs when the backing store raises on get" do
      raising = build_store(getter: ->(_k) { raise "boom" }, setter: ->(_k, _v) {})
      manager = described_class.new(store: raising, log_manager: log_manager)
      expect(manager.get("k")).to be_nil
      expect(sink.joined).to include("DataStoreManager#get")
    end

    it "swallows and logs when the backing store raises on set" do
      raising = build_store(getter: ->(_k) {}, setter: ->(_k, _v) { raise "boom" })
      manager = described_class.new(store: raising, log_manager: log_manager)
      expect { manager.set("k", "v") }.not_to raise_error
      expect(sink.joined).to include("DataStoreManager#set")
    end

    it "round-trips through the default MemoryStore" do
      manager = described_class.new(log_manager: log_manager)
      manager.set("k", "v")
      expect(manager.get("k")).to eq("v")
    end
  end

  describe "key formats — byte-exact JS parity (AC#3, AC#4)" do
    subject(:manager) { described_class.new(log_manager: log_manager) }

    it "builds the visitor key as {account_id}-{project_id}-{visitor_id}" do
      expect(manager.visitor_key("acc", "proj", "vis")).to eq("acc-proj-vis")
    end

    it "builds the config cache key as convert_sdk.config.{sdk_key}" do
      expect(manager.config_key("SDKKEY")).to eq("convert_sdk.config.SDKKEY")
    end

    it "lets a config entry and a visitor entry coexist in one store without collision" do
      manager.set(manager.config_key("SDKKEY"), {"experiences" => []})
      manager.merge_visitor_data("acc", "proj", "vis") { |_d| {"goals" => {"g1" => true}} }
      expect(manager.get(manager.config_key("SDKKEY"))).to eq({"experiences" => []})
      expect(manager.get(manager.visitor_key("acc", "proj", "vis"))).to eq({"goals" => {"g1" => true}})
    end
  end

  describe "StoreData merge semantics (AC#3)" do
    subject(:manager) { described_class.new(log_manager: log_manager) }

    it "deep-merges nested string-keyed hashes (JS objectDeepMerge)" do
      manager.merge_visitor_data("a", "p", "v") { |_d| {"bucketing" => {"exp1" => "var1"}} }
      result = manager.merge_visitor_data("a", "p", "v") { |_d| {"bucketing" => {"exp2" => "var2"}} }
      expect(result).to eq("bucketing" => {"exp1" => "var1", "exp2" => "var2"})
    end

    it "lets scalars from the new partial win" do
      manager.merge_visitor_data("a", "p", "v") { |_d| {"goals" => {"g1" => false}} }
      result = manager.merge_visitor_data("a", "p", "v") { |_d| {"goals" => {"g1" => true}} }
      expect(result).to eq("goals" => {"g1" => true})
    end

    it "unions arrays (deduped, new first) like JS" do
      manager.merge_visitor_data("a", "p", "v") { |_d| {"locations" => %w[x y]} }
      result = manager.merge_visitor_data("a", "p", "v") { |_d| {"locations" => %w[y z]} }
      expect(result["locations"]).to contain_exactly("x", "y", "z")
    end

    it "yields the current stored data to the block for atomic check-then-decide" do
      manager.merge_visitor_data("a", "p", "v") { |_d| {"goals" => {"g1" => true}} }
      seen = nil
      manager.merge_visitor_data("a", "p", "v") do |current|
        seen = current
        {}
      end
      expect(seen).to eq("goals" => {"g1" => true})
    end

    it "does not lose updates under concurrent merges incrementing distinct keys" do
      threads = Array.new(10) do |i|
        Thread.new do
          20.times do |j|
            manager.merge_visitor_data("a", "p", "v") { |_d| {"goals" => {"g-#{i}-#{j}" => true}} }
          end
        end
      end
      threads.each(&:join)
      goals = manager.get(manager.visitor_key("a", "p", "v"))["goals"]
      expect(goals.size).to eq(200)
    end
  end
end
