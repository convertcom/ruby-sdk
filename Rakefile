# frozen_string_literal: true

# NOTE: `bundler/gem_tasks` is deliberately NOT required. It defines `rake
# release`, whose `git_push` pushes the branch ref (the Android qs-03 GH013
# failure mode). Publishing happens exclusively via the OIDC release workflow
# (Epic 5) — `rake release` MUST NOT exist in this gem.

require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]
