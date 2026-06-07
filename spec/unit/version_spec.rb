# frozen_string_literal: true

RSpec.describe ConvertSdk do
  describe "VERSION" do
    subject(:version) { described_class::VERSION }

    it "is defined" do
      expect(version).not_to be_nil
    end

    it "is a semantic version string (MAJOR.MINOR.PATCH)" do
      expect(version).to match(/\A\d+\.\d+\.\d+/)
    end
  end
end
