# frozen_string_literal: true

# Load the Rails application.
require_relative "application"

# Initialize the Rails application (runs config/initializers/*, including
# convert_sdk.rb which builds the singleton CONVERT_SDK client).
Rails.application.initialize!
