# frozen_string_literal: true

source "https://rubygems.org"

# Runtime dependencies are declared in convert_sdk.gemspec — which is EMPTY by
# design (zero-runtime-deps architecture). All dev/test gems live here only,
# NEVER in the gemspec.
gemspec

# Build / task runner
gem "rake", "~> 13.0"

# Test framework + HTTP isolation + coverage (pinned tool versions — do not drift)
gem "rspec", "~> 3.13"
gem "simplecov", "~> 0.22.0", require: false
gem "webmock", "~> 3.26"

# Linting (RuboCop 1.87.x + performance cops)
gem "rubocop", "~> 1.87.0", require: false
gem "rubocop-performance", require: false

# Type checking
gem "rbs", require: false
gem "steep", require: false

# Documentation
gem "yard", require: false
