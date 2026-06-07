# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Redactor do
  # Mask is "first 4 chars + …" for secrets of length >= 4, else the whole
  # secret is replaced. The replacement glyph is the single-char ellipsis.
  let(:mask) { "…" }

  describe "#redact — secret masking" do
    # Each row: [secret, raw message, expected redacted message].
    [
      ["abcdef123456", "key is abcdef123456 here", "key is abcd… here"],
      ["abcdef123456", "abcdef123456 leads the line", "abcd… leads the line"],
      ["abcdef123456", "trailing abcdef123456", "trailing abcd…"],
      ["abc", "short abc secret", "short … secret"],
      ["ab", "two ab chars", "two … chars"],
      ["wxyz", "exactly wxyz four", "exactly wxyz… four"]
    ].each do |secret, raw, expected|
      it "masks #{secret.inspect} in #{raw.inspect}" do
        redactor = described_class.new([secret])
        expect(redactor.redact(raw)).to eq(expected)
      end
    end

    it "masks every occurrence of a repeated secret" do
      redactor = described_class.new(["abcdef"])
      expect(redactor.redact("abcdef and abcdef")).to eq("abcd… and abcd…")
    end

    it "masks multiple distinct secrets in one message" do
      redactor = described_class.new(%w[sdkkey12345 sekret98765])
      result = redactor.redact("k=sdkkey12345 s=sekret98765")
      expect(result).to eq("k=sdkk… s=sekr…")
    end

    it "treats secrets as literal text, not regex patterns" do
      redactor = described_class.new(["a.c+d"])
      expect(redactor.redact("literal a.c+d value")).to eq("literal a.c+… value")
    end
  end

  describe "#redact — URL query stripping" do
    [
      ["see https://host.com/path?x=1", "see https://host.com/path"],
      ["http://h/p?a=1&b=2 done", "http://h/p done"],
      ["https://host.com/path no query", "https://host.com/path no query"],
      ["pre https://h/a?k=v post https://h/b?j=w", "pre https://h/a post https://h/b"]
    ].each do |raw, expected|
      it "strips query from #{raw.inspect}" do
        expect(described_class.new([]).redact(raw)).to eq(expected)
      end
    end
  end

  describe "#redact — nil / empty safety" do
    [nil, "", "   "].each do |bad_secret|
      it "treats #{bad_secret.inspect} as a no-op secret" do
        redactor = described_class.new([bad_secret])
        expect(redactor.redact("untouched message")).to eq("untouched message")
      end
    end

    it "returns an empty string unchanged" do
      expect(described_class.new(["abcdef"]).redact("")).to eq("")
    end
  end

  describe "#register_secret — post-construction registration" do
    let(:redactor) { described_class.new([]) }

    it "masks a secret registered after construction" do
      redactor.register_secret("latekey12345")
      expect(redactor.redact("v=latekey12345")).to eq("v=late…")
    end

    it "ignores a nil/empty late secret" do
      redactor.register_secret(nil)
      redactor.register_secret("")
      expect(redactor.redact("v=latekey12345")).to eq("v=latekey12345")
    end

    it "combines construction-time and registered secrets" do
      r = described_class.new(["firstkey123"])
      r.register_secret("secondkey456")
      expect(r.redact("a=firstkey123 b=secondkey456")).to eq("a=firs… b=seco…")
    end
  end

  describe "combined redaction (secrets + URL)" do
    it "masks a secret AND strips a query in the same message" do
      r = described_class.new(["topsecret999"])
      out = r.redact("GET https://api.host/c/topsecret999?ts=1")
      expect(out).not_to include("topsecret999")
      expect(out).not_to include("?ts=1")
    end
  end
end
