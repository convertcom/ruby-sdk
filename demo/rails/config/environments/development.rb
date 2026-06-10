# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  # Eager-load even in development so `preload_app!` truly preloads (the fork
  # proof depends on the SDK client existing in the master before forking).
  config.eager_load = true
  config.consider_all_requests_local = true
  config.public_file_server.enabled = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "debug").to_sym
  config.hosts.clear if ENV["CONVERT_DEMO_DISABLE_HOST_CHECK"] == "1"
end
