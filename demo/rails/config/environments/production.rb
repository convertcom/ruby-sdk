# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = true
  config.eager_load = true
  config.consider_all_requests_local = true # demo: surface errors in responses
  config.public_file_server.enabled = false
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info").to_sym
  config.active_support.report_deprecations = false
  config.hosts.clear if ENV["CONVERT_DEMO_DISABLE_HOST_CHECK"] == "1"
end
