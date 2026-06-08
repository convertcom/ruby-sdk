# frozen_string_literal: true

# Steep-checked contract probe — SYNTHETIC VALUES ONLY. NOT runtime code.
#
# This file lives OUTSIDE lib/ (register #18 / architecture Decision 5) and is
# never required by the SDK. It exists solely as the build-time drift gate:
# Steep checks it as part of the :probe target (strict diagnostics), and any
# field the SDK depends on that has been dropped or renamed in the regenerated
# RBS will cause Steep to fail on the probe line that includes it.
#
# == How the drift gate fires
#
# Each call below passes a hash literal containing every field the SDK depends on
# to a typed helper method (sig/convert_sdk/config/probe_helpers.rbs). With
# strict diagnostics in the :probe Steepfile target:
#
#   1. When a depended field is REMOVED from the regenerated record type, the
#      hash literal here still includes that key.
#   2. Steep raises `UnknownRecordKey` (warning) + `ArgumentTypeMismatch` (error)
#      on the exact literal line — surfacing which field drifted.
#   3. `steep check` exits non-zero, blocking the backend-opened PR pre-merge.
#
# This is the true Ruby analogue of JS's typed consumers: the probe curates the
# "fields we depend on" surface explicitly. Adding a new reader dependency means
# adding that field to the literal below.
#
# == Additive-safe (AC2)
#
# When a NEW field is added to the record, the probe does NOT include it. Steep
# is silent (no error). The runtime readers use plain-hash `fetch`/`[]` which
# ignore unknown fields — additive changes never break either gate.
#
# == Field coverage rules (D6)
#
# Include ONLY fields the SDK reads AND that are declared in the generated RBS.
# Fields the SDK reads that the spec OMITS (spec-completeness gaps) are COMMENTED
# with a "D6 spec-gap" note — including them would produce a false positive.
#
# Current D6 spec-completeness gaps (backend follow-up required):
#   - experience["settings"] (matching_options.audiences) — absent from config_experience
#   - config_response_data["archived_experiences"] — absent from config_response_data
#   - goal fields: is_system, selected_default, status — absent from config_goal
#     (present in real config; recorded in research:F3/D6)

module ConvertSdk
  # ── config_response_data (the top-level "data" envelope) ──────────────────
  # D6 spec-gap: "archived_experiences" omitted (absent from config_response_data).
  probe_response_data_fields(
    "account_id" => nil,   # => DataManager#account_id reads data["account_id"]
    "project" => nil,      # => DataManager#project reads data["project"]
    "experiences" => nil,  # => DataManager#experiences reads data["experiences"]
    "features" => nil,     # => DataManager#features reads data["features"]
    "goals" => nil,        # => DataManager#goals reads data["goals"]
    "audiences" => nil,    # => DataManager#audiences reads data["audiences"]
    "segments" => nil,     # => DataManager#segments reads data["segments"]
    "locations" => nil     # => DataManager#locations reads data["locations"]
  )

  # ── config_project ─────────────────────────────────────────────────────────
  probe_project_fields(
    "id" => nil, # => DataManager#project_id reads project["id"]
    "name" => nil,
    "type" => nil
  )

  # ── config_experience ──────────────────────────────────────────────────────
  # D6 spec-gap: "settings" omitted (absent from config_experience; SDK reads
  # experience.dig("settings","matching_options","audiences") in all_match_required?).
  probe_experience_fields(
    "id" => nil,          # => eligible_experience, archived?, build_bucketed_variation
    "key" => nil,         # => find_by_key, build_bucketed_variation
    "name" => nil,        # => build_bucketed_variation
    "type" => nil,        # => present in spec; read via various gates
    "status" => nil,      # => environment + status gates
    "environment" => nil, # => environment_match? reads experience["environment"]
    "locations" => nil,   # => match_locations reads experience["locations"]
    "site_area" => nil,   # => match_locations reads experience["site_area"]
    "audiences" => nil,   # => audiences_to_check, custom_segments_matched?
    "variations" => nil,  # => variation_list reads experience["variations"]
    "goals" => nil        # => experience["goals"] consumed by readers
  )

  # ── experience_variation ───────────────────────────────────────────────────
  probe_variation_fields(
    "id" => nil,                 # => build_bucketed_variation, retrieve_variation, build_buckets
    "key" => nil,                # => build_bucketed_variation
    "name" => nil,               # => build_bucketed_variation
    "status" => nil,             # => bucketable_variation? reads variation["status"]
    "traffic_allocation" => nil, # => bucketable_variation?, build_buckets, build_bucketed_variation
    "changes" => nil             # => build_bucketed_variation reads variation["changes"]
  )

  # ── config_goal ────────────────────────────────────────────────────────────
  # D6 spec-gaps: "is_system", "selected_default", "status" omitted (present in
  # real config per test-config.json; absent from config_goal spec — F3/D6).
  probe_goal_fields(
    "id" => nil,   # => DataManager#convert reads goal["id"] for dedup + wire payload
    "name" => nil,
    "key" => nil,  # => find_by_key (goal_by_key) matches on goal["key"]
    "type" => nil, # => goal_type discriminator union (all 10 values — AC4)
    "rules" => nil # => rule walks reference goal["rules"]
  )

  # ── config_audience ────────────────────────────────────────────────────────
  probe_audience_fields(
    "id" => nil,   # => items_by_ids matching
    "key" => nil,  # => find_by_key
    "name" => nil,
    "type" => nil, # => audiences_to_check reads audience["type"] == "permanent"
    "rules" => nil # => matched_audiences walks audience["rules"]
  )

  # ── config_location ────────────────────────────────────────────────────────
  probe_location_fields(
    "id" => nil,   # => match_location_list / items_by_ids
    "key" => nil,  # => find_by_key
    "name" => nil,
    "rules" => nil # => match_location_list walks location["rules"]
  )

  # ── config_segment ─────────────────────────────────────────────────────────
  probe_segment_fields(
    "id" => nil,   # => custom_segments_matched? reads seg["id"]
    "key" => nil,  # => find_by_key
    "name" => nil,
    "rules" => nil
  )

  # ── config_feature ─────────────────────────────────────────────────────────
  probe_feature_fields(
    "id" => nil,       # => feature_by_key resolution chain
    "key" => nil,      # => find_by_key
    "name" => nil,
    "variables" => nil # => FeatureManager reads feature["variables"]
  )

  # ── feature_variable ───────────────────────────────────────────────────────
  probe_variable_fields(
    "key" => nil, # => FeatureManager reads variable["key"]
    "type" => nil # => feature_variable_type discriminator
  )

  # ── ga integration ─────────────────────────────────────────────────────────
  probe_ga_fields(
    "type" => nil, # => ga_integration_type discriminator (ga3 | ga4)
    "enabled" => nil
  )
end
