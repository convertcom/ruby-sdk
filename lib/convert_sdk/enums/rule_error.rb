# frozen_string_literal: true

require_relative "../sentinel"

module ConvertSdk
  # Rule-evaluation business misses, signaled as frozen singleton {Sentinel}s.
  #
  # Returned by audience/rule evaluation when a decision cannot be made. Wire
  # strings are byte-identical to the JS SDK
  # (javascript-sdk/packages/enums/src/rule-error.ts) and appear on the wire.
  module RuleError
    # No data was found to evaluate the rule. Wire: +convert.com_no_data_found+.
    NO_DATA_FOUND = Sentinel.new("convert.com_no_data_found")

    # More data is required before a decision can be made.
    # Wire: +convert.com_need_more_data+.
    NEED_MORE_DATA = Sentinel.new("convert.com_need_more_data")
  end
end
