# frozen_string_literal: true

module ConvertSdk
  # A successfully resolved feature — a frozen value object returned when a
  # feature decision is made (the success counterpart to a {Sentinel} miss).
  #
  # Implemented as a frozen +Struct+ subclass (NOT +Data.define+, which requires
  # Ruby 3.2; this gem's floor is 3.1). Members are snake_case, aligned to the JS
  # +BucketedFeature+ shape, verified against
  # javascript-sdk/packages/types/src/BucketedFeature.ts and the vendored
  # spec/fixtures/test-config.json feature entity. +status+ holds a
  # {FeatureStatus} wire value; +variables+ is the feature's variable map.
  class BucketedFeature < Struct.new(
    :experience_id,
    :experience_key,
    :experience_name,
    :id,
    :key,
    :name,
    :status,
    :variables,
    keyword_init: true
  )
    # @return [void] builds the struct then freezes it (immutable value object).
    def initialize(**)
      super
      freeze
    end

    # @return [Boolean] always false — a real decision is never a business miss.
    def error?
      false
    end
  end
end
