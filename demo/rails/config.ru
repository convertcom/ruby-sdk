# frozen_string_literal: true

# This file is used by Rack-based servers (Puma) to start the application.
require_relative "config/environment"

run Rails.application
