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
