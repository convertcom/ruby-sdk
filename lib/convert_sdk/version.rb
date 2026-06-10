# frozen_string_literal: true

module ConvertSdk
  # The gem version string (semantic version).
  #
  # This is a DEV PLACEHOLDER. The real version is written here at release time
  # by the semantic-release `@semantic-release/exec` prepareCmd (release.config.mjs),
  # as an UNCOMMITTED working-tree edit — the gem builds carrying the computed
  # version, but `main` never receives a version-bump commit. The next release
  # derives its version from this run's git tag, not from this file (FR66).
  # Mirrors the Android SDK's `0.0.0` placeholder in gradle/libs.versions.toml.
  # @return [String]
  VERSION = "0.0.0"
end
