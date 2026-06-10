# frozen_string_literal: true

RSpec.describe "ConvertSdk::VERSION" do
  subject(:version) { ConvertSdk::VERSION }

  it "is a non-nil string" do
    expect(version).to be_a(String)
  end

  it "is a semantic version (MAJOR.MINOR.PATCH)" do
    expect(version).to match(/\A\d+\.\d+\.\d+(?:[-+.][0-9A-Za-z.-]+)?\z/)
  end
end
