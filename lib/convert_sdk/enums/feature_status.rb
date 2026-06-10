# frozen_string_literal: true

module ConvertSdk
  # Feature toggle status. Wire values byte-identical to the JS SDK
  # (javascript-sdk/packages/enums/src/feature-status.ts).
  module FeatureStatus
    # The feature is on. Wire: +enabled+.
    ENABLED = "enabled"

    # The feature is off. Wire: +disabled+.
    DISABLED = "disabled"
  end
end
