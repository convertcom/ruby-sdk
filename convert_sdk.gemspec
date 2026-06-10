# frozen_string_literal: true

require_relative "lib/convert_sdk/version"

Gem::Specification.new do |spec|
  spec.name = "convert_sdk"
  spec.version = ConvertSdk::VERSION
  spec.authors = ["Convert Insights, Inc."]
  spec.email = ["support@convert.com"]

  spec.summary = "Convert Experiences FullStack Ruby SDK for A/B testing, feature flags, and personalizations."
  spec.description = "The official Convert Experiences Ruby SDK. Provides bucketing-compatible " \
                     "A/B testing, feature flag evaluation, and personalizations for server-side Ruby " \
                     "applications (Rails, Sinatra, Hanami, and plain scripts). Zero runtime dependencies."
  spec.homepage = "https://www.convert.com"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/convertcom/ruby-sdk"
  spec.metadata["changelog_uri"] = "https://github.com/convertcom/ruby-sdk/releases"
  spec.metadata["documentation_uri"] = "https://github.com/convertcom/ruby-sdk/wiki"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  #
  # The reject list keeps non-runtime files OUT of the packaged gem. The Node
  # release tooling (package.json / release.config.mjs / lockfiles / .releaserc /
  # node_modules) is DEV-ONLY: it drives semantic-release on the CI runner and
  # must NOT ship inside the gem — the gem keeps ZERO runtime deps and contains
  # no Node artifacts. (node_modules is also gitignored, so it won't appear in
  # `git ls-files`, but it is listed defensively.)
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[
                        bin/ test/ spec/ features/ docs/ demo/ sig/
                        .git .github appveyor Gemfile Steepfile
                        package.json package-lock.json yarn.lock .yarnrc.yml .yarn/
                        release.config.mjs .releaserc .npmrc node_modules/
                      ])
    end
  end
  spec.require_paths = ["lib"]

  # Runtime dependencies are EMPTY by design (zero-runtime-deps architecture —
  # stdlib only at runtime). Adding a runtime dependency is an architecture
  # change, not a story decision. All dev/test gems live in the Gemfile.
end
