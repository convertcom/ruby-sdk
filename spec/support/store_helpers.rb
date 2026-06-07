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
