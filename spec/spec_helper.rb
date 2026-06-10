# frozen_string_literal: true

# --- Quality rails (single source of truth) -------------------------------
# Coverage gates are declared ONCE here. No other file declares thresholds.
#
# Branch coverage and the SimpleCov gates run on CRuby only. JRuby runs the
# suite WITHOUT the coverage gate (architecture: JRuby coverage carve-out),
# guarded on RUBY_ENGINE so the JRuby matrix leg stays green.
#
# DISABLE_COVERAGE=1 opts a process out entirely. The dedicated parity job
# (qa.yml) sets it: that job runs only the narrow spec/cross_sdk subset as the
# release-blocking hashing gate (NFR18) and is intentionally independent of
# coverage — coverage is enforced by the full-suite `test` matrix job. Without
# this opt-out, .rspec's `--require spec_helper` would apply the global 85% line
# gate to the parity subset, which exercises only the hashing path.
COVERAGE_ENABLED = RUBY_ENGINE != "jruby" && ENV["DISABLE_COVERAGE"] != "1"

if COVERAGE_ENABLED
  require "simplecov"

  # Per-group line+branch floor for the critical algorithm units. SimpleCov
  # 0.22 has no first-class per-group minimum API, so we enforce it ourselves
  # in a top-level at_exit hook. The groups reference files that land in later
  # stories (murmur_hash3.rb in 1.2, bucketing_manager.rb in 2.9, etc.) — the
  # gate is inert until a group actually has tracked files, then activates
  # automatically.
  CRITICAL_GROUPS = {
    "Hashing" => ["lib/convert_sdk/murmur_hash3.rb"],
    "Bucketing" => ["lib/convert_sdk/bucketing_manager.rb"],
    "Rules" => ["lib/convert_sdk/rule_manager.rb", "lib/convert_sdk/comparisons.rb"]
  }.freeze
  CRITICAL_GROUP_MINIMUM = 95.0

  # Register the per-group gate as a TOP-LEVEL at_exit BEFORE SimpleCov.start.
  # Ruby runs at_exit hooks LIFO, so this fires AFTER SimpleCov's own exit hook
  # (which formats the report and enforces the global `minimum_coverage line: 85`
  # build-failing gate). We must NOT pass a custom block to `SimpleCov.start`'s
  # own `at_exit`, because doing so replaces SimpleCov's default exit hook and
  # silently disables the global minimum_coverage enforcement.
  at_exit do
    # Only run when SimpleCov produced a result for this process.
    if SimpleCov.running == false && SimpleCov.result?
      failures = []
      result_files = SimpleCov.result.files
      CRITICAL_GROUPS.each do |group_name, members|
        tracked = result_files.select do |file|
          members.any? { |m| file.filename.end_with?(m) }
        end
        next if tracked.empty? # inert until the group has files

        tracked.each do |file|
          line_cov = file.covered_percent
          if line_cov < CRITICAL_GROUP_MINIMUM
            failures << "#{group_name}: #{file.filename} line #{line_cov.round(2)}% < #{CRITICAL_GROUP_MINIMUM}%"
          end

          branch_cov = file.branch_covered_percent
          if branch_cov && branch_cov < CRITICAL_GROUP_MINIMUM
            failures << "#{group_name}: #{file.filename} branch #{branch_cov.round(2)}% < #{CRITICAL_GROUP_MINIMUM}%"
          end
        end
      end

      unless failures.empty?
        warn "SimpleCov critical-group coverage gate FAILED (>= #{CRITICAL_GROUP_MINIMUM}% line+branch):"
        failures.each { |f| warn "  #{f}" }
        exit 1
      end
    end
  end

  SimpleCov.start do
    enable_coverage :branch

    add_filter %r{^/spec/}
    add_filter %r{^/bin/}

    # Pinned coverage groups (architecture: SimpleCov group membership pinned).
    add_group "Hashing", "lib/convert_sdk/murmur_hash3.rb"
    add_group "Bucketing", "lib/convert_sdk/bucketing_manager.rb"
    add_group "Rules", ["lib/convert_sdk/rule_manager.rb", "lib/convert_sdk/comparisons.rb"]

    # Global build-failing line gate — active from day one. Enforced by
    # SimpleCov's own at_exit hook (left intact above).
    minimum_coverage line: 85
  end
end

require "webmock/rspec"

# All external HTTP disabled by default. Tests must stub explicitly.
WebMock.disable_net_connect!(allow_localhost: false)

require "convert_sdk"

# Load shared support files (test doubles, helpers) before configuring RSpec.
Dir[File.join(__dir__, "support", "**", "*.rb")].each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end
