# frozen_string_literal: true

module ConvertSdk
  # A successfully bucketed variation — a frozen value object returned when a
  # visitor IS decided into a variation (the success counterpart to a {Sentinel}
  # business miss).
  #
  # Implemented as a frozen +Struct+ subclass (NOT +Data.define+, which requires
  # Ruby 3.2; this gem's floor is 3.1). Members are snake_case, aligned to the JS
  # +BucketedVariation+ shape (+ExperienceVariationConfig+ plus the experience
  # fields), verified against javascript-sdk/packages/types/src/BucketedVariation.ts
  # and the vendored spec/fixtures/test-config.json variation entity.
  #
  #   v = ConvertSdk::BucketedVariation.new(key: "variation-a", id: "200381")
  #   case v.key
  #   when nil   then show_default          # a sentinel miss
  #   else            render(v.key)         # a real decision — error? is false
  #   end
  class BucketedVariation < Struct.new(
    :experience_id,
    :experience_key,
    :experience_name,
    :bucketing_allocation,
    :id,
    :key,
    :name,
    :status,
    :traffic_allocation,
    :changes,
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
