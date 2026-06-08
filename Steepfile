# frozen_string_literal: true

target :lib do
  signature "sig"

  check "lib"

  # Stdlib RBS for the hardened HTTP port (Story 1.5). Declared so Steep can
  # resolve Net::HTTP / URI::Generic / JSON at the single Net::HTTP site.
  library "net-http"
  library "uri"
  library "json"
end

# Build-time config-contract drift probe (qs-03 / architecture Decision 5).
# A dedicated target with strict code diagnostics so that when the regenerated
# RBS removes a field the probe's hash literal still includes, Steep raises
# ArgumentTypeMismatch (error-level) on the literal line — surfacing spec drift
# before the PR can merge. Strict is scoped here ONLY — lib/ remains on the
# default diagnostic profile.
target :probe do
  signature "sig"

  check "steep/config_contract_probe.rb"

  configure_code_diagnostics(Steep::Diagnostic::Ruby.strict)

  library "net-http"
  library "uri"
  library "json"
end
