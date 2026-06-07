# frozen_string_literal: true

require_relative "lib/convert_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "convert_sdk"
  spec.version = ConvertSdk::VERSION
  spec.authors = ["Convert Insights, Inc."]
  spec.email = ["support@convert.com"]

  spec.summary = "Convert Experiences FullStack SDK for Ruby."
  spec.description = "Zero-dependency Ruby SDK for the Convert Experiences platform: " \
                     "feature flags, A/B testing, and server-side experimentation with " \
                     "deterministic bucketing that is consistent across all Convert SDKs."
  spec.homepage = "https://www.convert.com"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/convertcom/ruby-sdk"
  spec.metadata["changelog_uri"] = "https://github.com/convertcom/ruby-sdk/releases"
  spec.metadata["documentation_uri"] = "https://convertcom.github.io/ruby-sdk"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files are added to the gem when it is released.
  # `git ls-files` loads tracked files; spec/demo/docs/tooling are excluded.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ demo/ docs/ sig/ features/ .git .github Gemfile])
    end
  end
  spec.require_paths = ["lib"]

  # Runtime dependencies: NONE — zero-dependency rule (frozen register #4 / FR58).
  # stdlib only at runtime. All dev/test gems live in the Gemfile, never here.
end
