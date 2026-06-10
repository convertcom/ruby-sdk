# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Sentinel do
  let(:wire) { "convert.com_no_data_found" }
  let(:sentinel) { described_class.new(wire) }

  describe "#to_s" do
    it "returns the byte-identical wire string it was constructed with" do
      expect(sentinel.to_s).to eq(wire)
    end
  end

  describe "#key" do
    it "returns nil so `case variation&.key` falls through to else" do
      expect(sentinel.key).to be_nil
    end
  end

  describe "#error?" do
    it "is true (sentinels always signal a business miss)" do
      expect(sentinel.error?).to be(true)
    end
  end

  describe "frozen-ness" do
    it "is frozen at construction" do
      expect(sentinel).to be_frozen
    end

    it "freezes the wire string it exposes" do
      expect(sentinel.to_s).to be_frozen
    end
  end

  describe "identity comparison" do
    it "is .equal? to itself (singleton identity for granular handling)" do
      expect(sentinel.equal?(sentinel)).to be(true)
    end

    it "is NOT .equal? to a distinct sentinel built from the same wire string" do
      other = described_class.new(wire)
      expect(sentinel.equal?(other)).to be(false)
    end
  end
end
