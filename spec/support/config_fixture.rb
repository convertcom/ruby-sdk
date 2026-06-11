# frozen_string_literal: true

require "json"

# Shared loader for the vendored behavioral fixture +spec/fixtures/test-config.json+
# (Story 1.2 — the cross-SDK canonical config shape with real +experiences+,
# +features+, +goals+, +audiences+, +segments+, +project+ rows).
#
# Direct-data-mode construction (a client/DataManager built straight from this
# parsed flat config, no network) is the standard way specs exercise the config
# readers and the Context lookup surface. Lives in +spec/support/+ (frozen file
# name +config_fixture.rb+) so every spec shares ONE loader instead of re-reading
# and re-parsing the file inline (keeps fixture coupling in one place).
module ConfigFixture
  # Absolute path to the vendored config fixture.
  PATH = File.expand_path("../fixtures/test-config.json", __dir__)

  module_function

  # Parse the vendored flat config fresh on each call (callers may freely
  # mutate the returned hash before constructing a client — e.g. to inject a
  # symbol-keyed variant — without bleeding into other examples).
  #
  # @return [Hash{String=>Object}] the parsed flat config (entities at the root:
  #   +account_id+, +project+, +experiences+, +features+, +goals+, etc.).
  def config
    JSON.parse(File.read(PATH))
  end

  # The +account_id+ declared in the fixture — the account half of the
  # +{account}-{project}-{visitor}+ visitor store key.
  # @return [String]
  def account_id
    config["account_id"]
  end

  # The +project.id+ declared in the fixture — the project half of the visitor
  # store key.
  # @return [String]
  def project_id
    config.dig("project", "id")
  end
end
