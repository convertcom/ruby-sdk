# frozen_string_literal: true

source "https://rubygems.org"

# convert_sdk.gemspec declares ZERO runtime dependencies (frozen register #4 / FR58).
# Every dev/test dependency is declared here and ONLY here — never in the gemspec.
gemspec

# Build / task runner
gem "rake", "~> 13.0"

# Test framework
gem "rspec", "~> 3.13.0"

# HTTP stubbing — external connections disabled by default in spec_helper.
gem "webmock", "~> 3.26.0"

# Coverage gates (configured once in spec/spec_helper.rb).
gem "simplecov", "~> 0.22.0"

# Lint
gem "rubocop", "~> 1.87.0"
gem "rubocop-performance", "~> 1.21"

# Type checking
gem "rbs", "~> 3.5"
gem "steep", "~> 1.7"

# Documentation
gem "yard", "~> 0.9"
