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
  end
end
