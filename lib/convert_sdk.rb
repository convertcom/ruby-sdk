# frozen_string_literal: true

require_relative "convert_sdk/version"
require_relative "convert_sdk/murmur_hash3"
require_relative "convert_sdk/sentinel"
require_relative "convert_sdk/enums/rule_error"
require_relative "convert_sdk/enums/bucketing_error"

module ConvertSdk
  class Error < StandardError; end
end
