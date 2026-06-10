# frozen_string_literal: true

module ConvertSdk
  # Recognized keys for conversion goal data (consumed by conversion tracking,
  # Story 4.3). Wire strings byte-identical to the JS SDK
  # (javascript-sdk/packages/enums/src/goal-data-key.ts).
  module GoalDataKey
    # Revenue amount. Wire: +amount+.
    AMOUNT = "amount"
    # Number of products. Wire: +productsCount+.
    PRODUCTS_COUNT = "productsCount"
    # Transaction identifier. Wire: +transactionId+.
    TRANSACTION_ID = "transactionId"
    # Custom dimension 1. Wire: +customDimension1+.
    CUSTOM_DIMENSION_1 = "customDimension1"
    # Custom dimension 2. Wire: +customDimension2+.
    CUSTOM_DIMENSION_2 = "customDimension2"
    # Custom dimension 3. Wire: +customDimension3+.
    CUSTOM_DIMENSION_3 = "customDimension3"
    # Custom dimension 4. Wire: +customDimension4+.
    CUSTOM_DIMENSION_4 = "customDimension4"
    # Custom dimension 5. Wire: +customDimension5+.
    CUSTOM_DIMENSION_5 = "customDimension5"

    # All recognized goal-data keys, in declaration order. Frozen array for
    # validation use (Story 4.3).
    ALL = [
      AMOUNT, PRODUCTS_COUNT, TRANSACTION_ID,
      CUSTOM_DIMENSION_1, CUSTOM_DIMENSION_2, CUSTOM_DIMENSION_3,
      CUSTOM_DIMENSION_4, CUSTOM_DIMENSION_5
    ].freeze

    # The two-worlds mapping (Story 4.3): the PUBLIC Ruby +track_conversion+
    # +goal_data:+ surface accepts snake_case symbol keys; this is the SINGLE
    # place the snake_case input is translated to the camelCase WIRE identifier.
    # The conversion build site (DataManager#convert) consults this map to
    # validate caller keys and emit the wire-correct +[{key, value}]+ pairs;
    # any key absent here is unknown and rejected. Frozen so it cannot drift.
    RUBY_KEY_MAP = {
      amount: AMOUNT,
      products_count: PRODUCTS_COUNT,
      transaction_id: TRANSACTION_ID,
      custom_dimension_1: CUSTOM_DIMENSION_1,
      custom_dimension_2: CUSTOM_DIMENSION_2,
      custom_dimension_3: CUSTOM_DIMENSION_3,
      custom_dimension_4: CUSTOM_DIMENSION_4,
      custom_dimension_5: CUSTOM_DIMENSION_5
    }.freeze

    # Translate a single caller-supplied +goal_data+ key (symbol or string,
    # snake_case OR the camelCase wire form) to its wire identifier, or +nil+
    # when the key is not one of the eight platform keys (caller rejects it).
    # Accepting the wire form too keeps the surface forgiving for integrators
    # who already know the platform identifiers.
    #
    # @param key [Symbol, String] the caller key.
    # @return [String, nil] the wire identifier, or nil when unrecognized.
    def self.wire_key_for(key)
      RUBY_KEY_MAP[key.to_sym] || (ALL.include?(key.to_s) ? key.to_s : nil)
    end
  end
end
