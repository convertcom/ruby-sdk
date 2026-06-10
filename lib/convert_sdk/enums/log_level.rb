# frozen_string_literal: true

module ConvertSdk
  # Logging verbosity levels, ordered least-to-most severe. Integer values are
  # JS-parity, verified against javascript-sdk/packages/enums/src/log-level.ts.
  # Consumed by LogManager (Story 1.4): a message logs when its level is >= the
  # configured threshold; +SILENT+ suppresses everything.
  module LogLevel
    # Finest-grained tracing.
    TRACE = 0
    # Debug diagnostics.
    DEBUG = 1
    # Informational messages.
    INFO = 2
    # Warnings.
    WARN = 3
    # Errors.
    ERROR = 4
    # Suppress all logging.
    SILENT = 5
  end
end
