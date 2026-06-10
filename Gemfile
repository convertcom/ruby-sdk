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

# `logger` is a bundled (not default) gem on Ruby 3.4+ and under JRuby, so it is
# not require-able under `bundle exec` unless declared. The log-manager spec
# requires it to prove a REAL stdlib Logger is accepted as a sink. Test-only —
# the SDK itself is duck-typed and NEVER requires logger; this stays out of the
# (empty) gemspec.
gem "logger", require: false

# Linting (RuboCop 1.87.x + performance cops)
gem "rubocop", "~> 1.87.0", require: false
gem "rubocop-performance", require: false

# Type checking (CRuby-only). `rbs` ships a C native extension
# (ext/rbs_extension) that cannot build under JRuby (universal-java); `steep`
# depends on `rbs`. Isolated in the :typecheck group so the JRuby test matrix
# leg installs via `BUNDLE_WITHOUT=typecheck` (set on the `test` job in qa.yml)
# without attempting the C-extension build. The CRuby `typecheck` job installs
# this group and runs `rbs validate` + `steep check`.
#
# rbs ~> 4.0 / steep ~> 2.0 require Ruby >= 3.2. The `test` matrix job runs
# `bundle lock` on Ruby 3.1 too and resolves ALL groups even with
# BUNDLE_WITHOUT=typecheck, so an unsatisfiable pin breaks the 3.1 lock.
# Declaring the group only on >= 3.2 omits it entirely on 3.1 (where typecheck
# never runs anyway — the dedicated typecheck job is CRuby 3.4 only).
# Gem::Version comparison is used (not string compare) to correctly order
# versions like "3.10" vs "3.2" in future Ruby release lines.
if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.2")
  group :typecheck do
    # Pinned with pessimistic constraints (qs-03 / D9): a minor bump cannot
    # silently flip the gate's verdict. Versions currently resolving green:
    # rbs 4.0.2, steep 2.0.0. No Gemfile.lock committed (matrix design) —
    # pessimistic constraint is the only pin.
    gem "rbs", "~> 4.0", require: false
    gem "steep", "~> 2.0", require: false
  end
end

# Documentation
gem "yard", require: false
