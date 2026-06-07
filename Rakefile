# frozen_string_literal: true

# NOTE: `bundler/gem_tasks` is intentionally NOT required (frozen register #16 / FR67).
# It exposes `rake release`, whose `git_push` pushes the branch ref — the Android
# qs-03 GH013 failure mode. Publishing happens exclusively via the OIDC release.yml
# workflow (Epic 5). Do not re-add it.
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]
