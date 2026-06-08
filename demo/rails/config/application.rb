# frozen_string_literal: true

require_relative "boot"

# A minimal Rails stack — we load ONLY the railties the demo needs (action_controller
# for the API endpoints). No Active Record (the demo has no database), no Action
# Mailer / Active Job / Action Cable, so the Docker boot stays fast and the fork
# smoke has nothing extraneous to load before forking. This mirrors what
# `rails new --minimal --api` would leave behind, trimmed by hand so the demo is
# self-contained and reviewable.
require "rails"
require "action_controller/railtie"

# Bundler.require pulls in convert_sdk (the path gem) + rails + puma.
Bundler.require(*Rails.groups)

module ConvertRailsDemo
  # The demo application. Teaching material: this is the smallest Rails app that
  # exercises the Convert SDK under a real Puma cluster. Nothing here is
  # Convert-specific except the initializer + the controller concern.
  class Application < Rails::Application
    config.load_defaults 7.2

    # API-lean: no cookies/session middleware required for the demo flows (the
    # demo identity comes from a `visitor_id` param/header — see ConvertContext).
    config.api_only = true

    # Eager-load in all environments so `preload_app!` in config/puma.rb actually
    # loads the full app (controllers + the SDK initializer) in the Puma MASTER
    # before it forks workers. This is what makes the fork-safety proof real: the
    # SDK client is built ONCE in the preloading master and inherited by every
    # forked worker — the exact production shape.
    config.eager_load = true

    # Quiet, deterministic logging for the smoke (still visible in `docker compose up`).
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym

    # The demo serves only JSON; no view layer, no asset pipeline.
    config.hosts.clear if ENV["CONVERT_DEMO_DISABLE_HOST_CHECK"] == "1"

    # Rails requires a secret_key_base to boot in production. The demo ships NO
    # encrypted credentials (it's a throwaway example), so source it from ENV with
    # a fixed non-secret fallback — there is nothing sensitive to protect here (no
    # sessions, no signed cookies; api_only). A real app uses credentials/ENV.
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "convert-rails-demo-not-a-secret")
  end
end
