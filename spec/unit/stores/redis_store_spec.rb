# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Stores::RedisStore do
  # Injected fake client (FakeRedis lives in spec/support/store_helpers.rb). The
  # injection path never touches the `redis` gem, so the whole suite runs with
  # `redis` UNinstalled — proving the zero-gemspec-footprint contract.
  let(:client) { FakeRedis.new }
  subject(:store) { described_class.new(redis: client) }

  # AC#2: same duck-typed port contract as MemoryStore, via the ONE shared spec.
  it_behaves_like "a convert store"

  describe "client injection (AC#1)" do
    it "uses the injected client without lazily requiring redis" do
      # The lazy `require "redis"` + `Redis.new` only happen on the
      # connection-options path. On the injection path they must NEVER run —
      # that is what keeps the suite green with `redis` uninstalled. Asserting
      # `require "redis"` is never invoked proves the gem is not touched.
      expect_any_instance_of(described_class).not_to receive(:require)
      described_class.new(redis: client)
    end

    it "reads and writes through the injected client" do
      store.set("k", { "a" => 1 })
      expect(client.get("convert:k")).to eq(JSON.generate({ "a" => 1 }))
    end
  end

  describe "connection options (AC#1)" do
    # Exercise the REAL `build_client`: stub the lazy `require "redis"` to a
    # no-op (so the suite needs no `redis` gem) and supply a stand-in `Redis`
    # constant whose `.new` returns the in-memory fake. This drives both the
    # `require "redis"` line and `Redis.new(**options)` without a live Redis.
    before do
      stub_const("Redis", fake_redis_class)
      allow_any_instance_of(described_class).to receive(:require).with("redis").and_return(false)
    end

    let(:built) { FakeRedis.new }

    let(:fake_redis_class) do
      stand_in = built
      Class.new { define_singleton_method(:new) { |**_opts| stand_in } }
    end

    it "lazily requires redis and builds a client from connection options" do
      adapter = described_class.new(url: "redis://localhost:6379")
      adapter.set("k", "v")
      expect(built.get("convert:k")).to eq(JSON.generate("v"))
    end
  end

  describe "missing `redis` gem (AC#1)" do
    it "raises an actionable error naming the gem when the lazy require fails" do
      allow_any_instance_of(described_class)
        .to receive(:require).with("redis").and_raise(LoadError)

      expect { described_class.new(url: "redis://localhost") }
        .to raise_error(/redis/i, /gem 'redis'/)
    end
  end

  describe "JSON serialization round-trip (AC#2)" do
    # StoreData shape preservation: string-keyed nested hashes, numbers, arrays,
    # booleans, nil, and unicode. One parameterized example per case — no
    # copy-pasted assertion blocks (SonarQube CPD discipline).
    {
      "nested string-keyed hash" => { "bucketing" => { "exp1" => "varA" }, "goals" => { "g" => true } },
      "mixed numerics" => { "int" => 42, "float" => 3.14, "neg" => -7 },
      "array of mixed types" => ["a", 1, true, nil, { "k" => "v" }],
      "booleans and nil" => { "on" => true, "off" => false, "absent" => nil },
      "unicode string" => "héllo-wörld-✓-日本語",
      "empty structures" => { "emptyHash" => {}, "emptyArray" => [] }
    }.each do |label, value|
      it "preserves #{label} across set/get" do
        store.set("rt", value)
        expect(store.get("rt")).to eq(value)
      end

      it "stores #{label} as JSON text in the client" do
        store.set("rt", value)
        expect(client.get("convert:rt")).to eq(JSON.generate(value))
      end
    end

    it "returns nil (not parsed) for an unwritten key" do
      expect(store.get("missing")).to be_nil
    end
  end

  describe "key prefixing" do
    it "prefixes stored keys with the default namespace" do
      store.set("visitor-1", "data")
      expect(client.get("convert:visitor-1")).not_to be_nil
    end

    it "honors a custom key prefix" do
      prefixed = described_class.new(redis: client, key_prefix: "cv2:")
      prefixed.set("k", "v")
      expect(client.get("cv2:k")).to eq(JSON.generate("v"))
      expect(prefixed.get("k")).to eq("v")
    end
  end
end
