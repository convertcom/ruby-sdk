# frozen_string_literal: true

require "spec_helper"
require "json"

# Cross-SDK MurmurHash3 parity suite.
#
# This is the release-blocking proof that Ruby hashes byte-identically to every
# other Convert SDK. The goldens in `test-vectors.json` are vendored VERBATIM
# from php-sdk (see spec/fixtures/cross_sdk/PROVENANCE.md) and are never edited.
# Each vector is iterated data-driven (one generated example per record) — this
# is the architecture-mandated tabular pattern, and it keeps the file free of
# copy-pasted assertion blocks.
RSpec.describe "Cross-SDK MurmurHash3 parity" do
  vectors_path = File.expand_path("../fixtures/cross_sdk/test-vectors.json", __dir__)
  vectors = JSON.parse(File.read(vectors_path))

  describe "vendored test-vectors.json (#{vectors.length} vectors)" do
    it "vendors exactly 75 vectors (guards against a truncated/edited fixture)" do
      expect(vectors.length).to eq(75)
    end

    vectors.each do |vector|
      input = vector["input"]
      seed = vector["seed"]
      expected = vector["expected"]
      category = vector["category"]

      it "[#{category}] hashes #{input.inspect} (seed #{seed}) to #{expected}" do
        expect(ConvertSdk::MurmurHash3.hash(input, seed)).to eq(expected)
      end
    end

    it "honours the canonical cross-SDK anchor (testString @ 9999 => 2241850228)" do
      expect(ConvertSdk::MurmurHash3.hash("testString", 9999)).to eq(2_241_850_228)
    end
  end

  # Ruby-extension UTF-8 multi-byte cases. These EXTEND the vendored goldens
  # without editing them. We assert a STRUCTURAL invariant that holds for any
  # correct MurmurHash3 regardless of the specific output value: a multi-byte
  # string must hash over its UTF-8 byte sequence — i.e. identically to its raw
  # ASCII-8BIT byte view. Asserting invented numeric goldens here would not be
  # cross-SDK-proven, so we assert the byte-equivalence property instead.
  describe "UTF-8 multi-byte byte-equivalence (Ruby extension)" do
    multibyte_inputs = [
      "café",          # Latin-1 accented (2-byte é)
      "über",          # Latin-1 accented (2-byte ü)
      "こんにちは", # CJK (3-byte chars)
      "🎉",            # emoji (4-byte)
      "emoji🎉test",   # mixed ASCII + emoji
      "Ω≈ç√∫" # assorted multi-byte symbols
    ]

    multibyte_inputs.each do |str|
      it "hashes #{str.inspect} over its UTF-8 bytes (seed 9999)" do
        byte_view = str.dup.force_encoding(Encoding::ASCII_8BIT)
        expect(ConvertSdk::MurmurHash3.hash(str, 9999)).to eq(ConvertSdk::MurmurHash3.hash(byte_view, 9999))
      end

      it "produces a stable unsigned 32-bit value for #{str.inspect}" do
        result = ConvertSdk::MurmurHash3.hash(str, 9999)
        expect(result).to be_between(0, 0xFFFFFFFF).inclusive
      end
    end
  end
end
