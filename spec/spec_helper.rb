# frozen_string_literal: true

# ---------------------------------------------------------------------------
# Quality rails — declared ONCE here (architecture: single source of truth for
# coverage gates). Do not duplicate coverage thresholds in any other file.
# ---------------------------------------------------------------------------

# SimpleCov MUST be started before `require "convert_sdk"` so every loaded line
# is tracked. Branch coverage is a CRuby feature; JRuby runs the suite WITHOUT
# the coverage gate (frozen register: JRuby coverage carve-out).
ON_CRUBY = (RUBY_ENGINE == "ruby")

if ON_CRUBY
  require "simplecov"

  # Per-group line+branch minimum (>=95%). SimpleCov has no native per-group
  # gate, so enforce it ourselves in an at_exit hook AFTER SimpleCov computes
  # results. The gate is inert for any group whose files do not yet exist, so
  # it activates automatically as later stories land those files.
  GROUP_MIN_COVERAGE = 95.0
  PINNED_GROUP_FILES = {
    "Hashing" => ["lib/convert_sdk/murmur_hash3.rb"],
    "Bucketing" => ["lib/convert_sdk/bucketing_manager.rb"],
    "Rules" => ["lib/convert_sdk/rule_manager.rb", "lib/convert_sdk/comparisons.rb"]
  }.freeze

  SimpleCov.start do
    enable_coverage :branch
    primary_coverage :line

    # Global line gate active from day one (against version.rb / convert_sdk.rb).
    minimum_coverage line: 85

    add_filter "/spec/"
    add_filter "/bin/"

    # Pinned coverage groups. The matchers reference files that may not exist
    # yet (they land in later stories); the groups are simply empty until then.
    PINNED_GROUP_FILES.each do |name, files|
      add_group(name) { |src| files.any? { |f| src.filename.end_with?(f) } }
    end

    # Enforce >=95% line+branch on each pinned group that actually has files.
    at_exit do
      SimpleCov.result.format!

      failures = []
      SimpleCov.result.groups.each do |name, files|
        next unless PINNED_GROUP_FILES.key?(name)
        next if files.empty?

        line_pct = files.covered_percent
        branch_pct = files.respond_to?(:covered_branches) ? files.branch_covered_percent : 100.0

        failures << "#{name} line #{line_pct.round(2)}%" if line_pct < GROUP_MIN_COVERAGE
        failures << "#{name} branch #{branch_pct.round(2)}%" if branch_pct < GROUP_MIN_COVERAGE
      end

      unless failures.empty?
        warn "SimpleCov group gate failed (>= #{GROUP_MIN_COVERAGE}% line+branch): #{failures.join(", ")}"
        exit 1
      end
    end
  end
end

# All external HTTP is disabled by default. Specs that exercise the HTTP layer
# opt in explicitly via stubs (WebMock) — never real network.
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: false)

require "convert_sdk"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
