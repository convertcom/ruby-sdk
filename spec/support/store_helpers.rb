# frozen_string_literal: true

# Shared examples for the duck-typed Convert store port contract.
#
# Any store backing +DataStoreManager+ must satisfy this contract: a +get+/+set+
# round-trip and a +nil+ for unknown keys. +MemoryStore+ (Story 2.1) and
# +RedisStore+ (Story 2.2) both run these examples via
# +it_behaves_like "a convert store"+, so the parity contract lives in ONE place
# (no copy-paste across store specs).
#
# The host example group must define a +store+ subject (or +let(:store)+).
RSpec.shared_examples "a convert store" do
  it "round-trips a value through set/get" do
    store.set("k", "v")
    expect(store.get("k")).to eq("v")
  end

  it "round-trips a structured (string-keyed) value" do
    data = { "bucketing" => { "exp" => "var" }, "goals" => { "g1" => true } }
    store.set("structured", data)
    expect(store.get("structured")).to eq(data)
  end

  it "returns nil for an unknown key" do
    expect(store.get("never-written")).to be_nil
  end

  it "overwrites an existing key on a second set" do
    store.set("k", "first")
    store.set("k", "second")
    expect(store.get("k")).to eq("second")
  end
end

# Hand-rolled, in-memory fake of the tiny subset of the +redis-rb+ client API that
# {ConvertSdk::Stores::RedisStore} consumes — +#get(key)+ and +#set(key, value)+.
#
# We deliberately avoid +fakeredis+/+mock_redis+ and a live Redis: the unit suite
# MUST pass with the +redis+ gem NOT installed (the zero-gemspec-footprint litmus
# test for Story 2.2). This double models the real client's contract: values are
# stored and returned as raw strings, and a missing key reads as +nil+. It lives
# here (shared, not copy-pasted into the spec) so future store specs can reuse it.
class FakeRedis
  def initialize
    @data = {}
  end

  # Mirror +Redis#get+: returns the stored string, or +nil+ when the key is absent.
  def get(key)
    @data[key]
  end

  # Mirror +Redis#set+: stores +value+ (a string) and returns redis-rb's +"OK"+.
  def set(key, value)
    @data[key] = value
    "OK"
  end
end
