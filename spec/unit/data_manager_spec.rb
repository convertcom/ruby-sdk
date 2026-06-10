# frozen_string_literal: true

require "spec_helper"

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
end
