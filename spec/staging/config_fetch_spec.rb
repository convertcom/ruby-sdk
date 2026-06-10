# frozen_string_literal: true

require "spec_helper"

# Story 5.1 AC#2 — live config-fetch schema-drift gate (FR65).
#
# A scheduled run fetches the REAL config from the shared staging project (the
# same project the JS/PHP demos use) through the public entry point
# (+ConvertSdk.create(sdk_key:)+) and asserts the fetched snapshot satisfies the
# STRUCTURAL contract the SDK's readers depend on — keys + types, NEVER exact
# values (staging content changes between runs; a value assertion would be a
# false alarm). If the platform drops a key the readers consume, or changes its
# type, THIS spec fails on the next scheduled run instead of a customer's
# integration silently degrading.
#
# The schema-expectation list is DERIVED FROM DataManager's readers (Story 2.5):
# every structure asserted here is one the SDK actually consumes —
#   * data.account_id / data.project.id          (store-key halves)
#   * data.experiences[] {id, key, variations[]}  (decision flow + bucketing)
#       variation {id, traffic_allocation}        (build_buckets)
#   * data.features[] {id, key, variables[]}      (feature resolution + casting)
#       variable {key, type}                      (cast_type)
#   * data.goals[] {id, key}                       (conversion tracking)
#   * data.audiences[] / data.segments[]           (audience/segment gates)
#       data.locations[] is OPTIONAL (some projects omit it — readers nil-safe)
#
# Tagged :staging so the default `rake` excludes it; the shared context skips
# cleanly without CONVERT_SDK_KEY and scopes real-HTTP to this group only.

# The wire shape mixes String and Integer ids across projects; accept both so a
# numeric-vs-string id change is NOT a false drift alarm (the readers to_s).
# Module-namespaced (not in-block) so RuboCop's Lint/ConstantDefinitionInBlock
# stays happy — the full_chain_spec precedent.
module ConfigSchemaTypes
  ID = [String, Integer].freeze
end

RSpec.describe "Live config fetch schema (Story 5.1 AC#2)", :staging do
  include_context "a live staging run"

  # Surface the id-type list by bare name inside the (lexically-scoped) blocks.
  let(:id_types) { ConfigSchemaTypes::ID }

  # Build a live fetch-mode client against the staging project. Timer-off
  # (data_refresh_interval: nil) so no background thread spawns; the secret
  # is attached only when the with-secret variant's credentials include one.
  let(:client) do
    creds = staging_credentials
    opts = { sdk_key: creds[:sdk_key], data_refresh_interval: nil }
    opts[:sdk_key_secret] = creds[:sdk_key_secret] if creds[:sdk_key_secret]
    ConvertSdk.create(**opts)
  end

  # The reader surface — the SDK's ONLY config-read boundary. Every assertion
  # below probes a reader, never a raw config hash (there is no raw accessor).
  let(:dm) { client.data_manager }

  # ── Structural assertion helpers (shared, tabular — no per-field copy-paste) ──

  # Assert that +value+ is present (non-nil) and an instance of one of +types+.
  # The single leaf assertion every tabular check funnels through.
  def expect_type(value, types, label)
    expect(value).not_to be_nil, "#{label}: expected present, got nil"
    expect(types.any? { |t| value.is_a?(t) }).to be(true),
                                                 "#{label}: expected one of #{types.inspect}, got #{value.class}"
  end

  # Assert each [reader-result, allowed-types, label] row in a table. Drives the
  # scalar reader checks (account_id, project_id) without repeating the shape.
  def assert_scalar_table(rows)
    rows.each { |value, types, label| expect_type(value, types, label) }
  end

  # Assert a collection reader returns an Array and, when non-empty, that its
  # first element carries each [key, allowed-types] pair. A staging project is
  # expected to be populated, so an empty required collection is itself drift —
  # +require_present+ enforces that; optional collections (locations) skip it.
  def assert_collection(items, field_pairs, label, require_present: true)
    expect(items).to be_an(Array), "#{label}: expected Array, got #{items.class}"
    expect(items).not_to be_empty, "#{label}: expected a populated collection (staging drift?)" if require_present
    return if items.empty?

    sample = items.first
    expect(sample).to be_a(Hash), "#{label}[0]: expected Hash, got #{sample.class}"
    field_pairs.each { |key, types| expect_type(sample[key], types, "#{label}[0].#{key}") }
  end

  it "fetches a config the SDK can read (config_available? true)" do
    expect(client.config_available?).to be(true)
  end

  it "exposes the account/project identity scalars the store key depends on" do
    assert_scalar_table(
      [
        [dm.account_id, id_types, "data.account_id"],
        [dm.project_id, id_types, "data.project.id"]
      ]
    )
  end

  it "exposes experiences with the {id, key, variations} the decision flow reads" do
    assert_collection(dm.experiences, [["id", id_types], ["key", [String]], ["variations", [Array]]],
                      "data.experiences")
  end

  it "exposes variations carrying the {id, traffic_allocation} the bucketer reads" do
    variations = dm.experiences.flat_map { |e| e["variations"] || [] }
    assert_collection(variations, [["id", id_types], ["traffic_allocation", [Integer, Float]]],
                      "experience.variations")
  end

  it "exposes features with the {id, key, variables} feature resolution reads" do
    assert_collection(dm.features, [["id", id_types], ["key", [String]], ["variables", [Array]]],
                      "data.features")
  end

  it "exposes feature variables carrying the {key, type} the type-caster reads" do
    variables = dm.features.flat_map { |f| f["variables"] || [] }
    assert_collection(variables, [["key", [String]], ["type", [String]]], "feature.variables")
  end

  it "exposes goals with the {id, key} conversion tracking reads" do
    assert_collection(dm.goals, [["id", id_types], ["key", [String]]], "data.goals")
  end

  it "exposes audiences and segments as collections the rule gates read" do
    assert_collection(dm.audiences, [], "data.audiences", require_present: false)
    assert_collection(dm.segments, [], "data.segments", require_present: false)
  end

  it "exposes locations as an Array when present (optional — readers nil-safe to [])" do
    # Locations are optional in the wire shape; assert only that the reader keeps
    # its [] contract (never nil) — presence is not required.
    assert_collection(dm.locations, [], "data.locations", require_present: false)
  end
end
