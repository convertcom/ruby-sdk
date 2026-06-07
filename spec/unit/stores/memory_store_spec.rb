# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Stores::MemoryStore do
  subject(:store) { described_class.new }

  it_behaves_like "a convert store"

  describe "thread safety" do
    # N threads hammering distinct keys must not lose writes or raise. The
    # Hash itself is not thread-safe under concurrent mutation on every Ruby
    # engine; the Mutex inside MemoryStore is what makes this pass.
    it "stores every write under concurrent set across distinct keys" do
      threads = Array.new(20) do |i|
        Thread.new do
          50.times { |j| store.set("k-#{i}-#{j}", "#{i}:#{j}") }
        end
      end
      threads.each(&:join)

      20.times do |i|
        50.times do |j|
          expect(store.get("k-#{i}-#{j}")).to eq("#{i}:#{j}")
        end
      end
    end

    it "does not raise under concurrent get/set on the same key" do
      expect do
        threads = Array.new(10) do
          Thread.new do
            100.times do
              store.set("shared", "value")
              store.get("shared")
            end
          end
        end
        threads.each(&:join)
      end.not_to raise_error
    end
  end
end
