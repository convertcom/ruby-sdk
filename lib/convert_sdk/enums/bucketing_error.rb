# frozen_string_literal: true

require_relative "../sentinel"

module ConvertSdk
  # Bucketing business misses, signaled as frozen singleton {Sentinel}s.
  #
  # Wire strings are byte-identical to the JS SDK
  # (javascript-sdk/packages/enums/src/bucketing-error.ts). NOTE: the JS source
  # has a typo in the constant *name* (+VARIAION_NOT_DECIDED+, missing the "T").
  # The Ruby constant spelling is CORRECTED to {VARIATION_NOT_DECIDED}; the wire
  # string +convert.com_variation_not_decided+ is left byte-identical to JS.
  module BucketingError
    # No variation could be decided for the visitor.
    # Wire: +convert.com_variation_not_decided+ (byte-identical to JS).
    VARIATION_NOT_DECIDED = Sentinel.new("convert.com_variation_not_decided")
  end
end
