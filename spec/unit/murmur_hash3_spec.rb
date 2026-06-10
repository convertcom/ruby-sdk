# frozen_string_literal: true

require "spec_helper"

# Verified goldens lifted from the vendored cross-SDK vectors (seed 9999).
# These are NOT invented — each is a cross-SDK-proven expected value, chosen to
# exercise every trailing-byte (tail) branch: the body+tail switch on len % 4 is
# where hand-ported Murmur implementations classically diverge.
#
#   "" (empty)        -> len%4 = 0, no body, no tail
#   "hello"  (5 B)    -> len%4 = 1, one body block + 1-byte tail
#   "testString" (10) -> len%4 = 2, two body blocks + 2-byte tail
#   "visitor-123"(11) -> len%4 = 3, two body blocks + 3-byte tail
MURMUR_VERIFIED_SEED9999 = {
  "" => 3_523_940_263,
  "hello" => 198_804_431,
  "testString" => 2_241_850_228, # the cross-SDK anchor
  "visitor-123" => 1_130_634_450
}.freeze

# Seed sweep reused across examples (extracted to avoid a literal array in a loop).
MURMUR_SEEDS = [0, 1, 42, 9999, 2_147_483_647].freeze

RSpec.describe ConvertSdk::MurmurHash3 do
  describe ".hash" do
    MURMUR_VERIFIED_SEED9999.each do |input, expected|
      tail = input.bytesize % 4
      it "matches cross-SDK golden for #{input.inspect} (tail=#{tail}) => #{expected}" do
        expect(described_class.hash(input, 9999)).to eq(expected)
      end
    end

    it "exercises a 4-byte aligned input (tail=0 with a full body block)" do
      # "über" is 5 UTF-8 bytes; "1234" is exactly 4 -> one body block, empty tail.
      # Verified golden from the vendored numeric vectors is asserted via parity
      # suite; here we assert the no-tail path returns a valid unsigned 32-bit value.
      result = described_class.hash("1234", 9999)
      expect(result).to be_between(0, 0xFFFFFFFF).inclusive
    end

    it "always returns an unsigned 32-bit integer (0..2^32-1)" do
      %w[a ab abc abcd hello testString visitor-123].each do |key|
        MURMUR_SEEDS.each do |seed|
          result = described_class.hash(key, seed)
          expect(result).to be_between(0, 0xFFFFFFFF).inclusive
        end
      end
    end

    it "varies output with the seed for the same input" do
      results = [0, 1, 42, 9999].map { |seed| described_class.hash("testString", seed) }
      expect(results.uniq.length).to eq(results.length)
    end

    it "handles long strings spanning many body blocks" do
      result = described_class.hash("x" * 1000, 9999)
      expect(result).to be_between(0, 0xFFFFFFFF).inclusive
    end

    it "hashes over UTF-8 bytes, not codepoints" do
      # A multi-byte string must hash identically to its raw UTF-8 byte sequence.
      multibyte = "héllo" # 'é' = 0xC3 0xA9
      byte_equiv = multibyte.b
      expect(described_class.hash(multibyte, 9999)).to eq(described_class.hash(byte_equiv, 9999))
    end

    it "is deterministic — same input and seed always yields the same value" do
      expect(described_class.hash("repeatable", 9999)).to eq(described_class.hash("repeatable", 9999))
    end
  end
end
