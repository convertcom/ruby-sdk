# frozen_string_literal: true

require_relative "convert_sdk/version"
require_relative "convert_sdk/murmur_hash3"
require_relative "convert_sdk/sentinel"
require_relative "convert_sdk/enums/rule_error"
require_relative "convert_sdk/enums/bucketing_error"
require_relative "convert_sdk/enums/feature_status"
require_relative "convert_sdk/enums/log_level"
require_relative "convert_sdk/enums/system_events"
require_relative "convert_sdk/enums/goal_data_key"

module ConvertSdk
  class Error < StandardError; end
end
