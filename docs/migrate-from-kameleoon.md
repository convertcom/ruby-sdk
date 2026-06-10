# Migrating from Kameleoon (server-side)

> **Status: outline.** This guide maps the Kameleoon server-side concepts to the
> Convert Ruby SDK at a conceptual level. The full, code-complete migration guide
> is written **during the pilot**, against the launch customer's actual Kameleoon
> usage — so it documents real call-site translations rather than speculative
> ones. The sections marked _[Pilot]_ below are intentional placeholders.

## Concept map

| Kameleoon (server-side) | Convert Ruby SDK | Notes |
|-------------------------|------------------|-------|
| Feature experiment / experiment activation | [`context.run_experience(key)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_experience-instance_method) | Returns a `BucketedVariation` (hit) or `Sentinel` (miss). Branch on `variation&.key`. |
| Feature flag evaluation | [`context.run_feature(key)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_feature-instance_method) | Returns a `BucketedFeature`; branch on `#status`. |
| Feature variables / variation parameters | `BucketedFeature#variables` (typed) | Variables arrive cast to their declared types. |
| Goal / conversion tracking | [`context.track_conversion(goal_key, goal_data:)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#track_conversion-instance_method) | Revenue/transaction data goes in `goal_data:` (the `goalData` equivalent), deduplicated per visitor per goal. |
| Visitor code | Visitor id (`create_context(visitor_id)`) | One `Context` per visitor per request/job. |
| Custom data / visitor attributes | Context `attributes` + [`update_visitor_properties`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#update_visitor_properties-instance_method) | Attributes drive audience/segment matching; properties persist (sticky). |
| Segments / targeting | [`set_default_segments`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#set_default_segments-instance_method) / [`run_custom_segments`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_custom_segments-instance_method) | Report-segments and rule-evaluated custom segments. |
| SDK client / configuration | [`ConvertSdk.create(sdk_key:)`](https://convertcom.github.io/ruby-sdk/ConvertSdk.html#create-class_method) | One client per process; see the [README](../README.md) and quickstarts. |
| Data file / config caching | `data:` (direct-data mode) + `store:` (RedisStore) | See the [README configuration table](../README.md#configuration). |
| Flush / send data | [`client.flush`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Client.html#flush-instance_method) | Background timer + explicit/`at_exit` flush. See the [troubleshooting guide](troubleshooting.md). |

## Migration steps _[Pilot]_

_[Pilot] — written against the customer's real integration. Will cover: client
bootstrap replacement, per-request context wiring, the experiment/feature call
translations, conversion-tracking translation, and a cutover/validation plan._

## Behavioral differences to watch _[Pilot]_

_[Pilot] — documents the concrete semantic differences encountered during the
pilot (sentinel-vs-exception miss handling, sticky-bucketing/store model,
fork-safety model) with real examples from the customer's code._

## Validation checklist _[Pilot]_

_[Pilot] — a parity checklist confirming decisions and conversions match between
the Kameleoon and Convert integrations during the dual-run period._
