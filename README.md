# Convert Ruby SDK

[![Quality Checks](https://github.com/convertcom/ruby-sdk/actions/workflows/qa.yml/badge.svg)](https://github.com/convertcom/ruby-sdk/actions/workflows/qa.yml)
[![Gem Version](https://badge.fury.io/rb/convert_sdk.svg)](https://rubygems.org/gems/convert_sdk)
[![API docs](https://img.shields.io/badge/API_docs-YARD-blue)](https://convertcom.github.io/ruby-sdk)

The official Convert Experiences FullStack Ruby SDK — server-side A/B testing,
feature flags, and personalizations for Ruby applications. Bucketing-compatible
with the Convert JavaScript SDK. **Zero runtime dependencies** (stdlib only).

- **Fork-safe with zero configuration** — works under Puma cluster, Unicorn,
  Passenger, Sidekiq, AWS Lambda, and plain CLI scripts. See
  [Fork safety](#fork-safety-zero-config) below — it's the differentiator.
- **Never crashes the host** — every public method degrades to a documented
  return value and a log line; only misconfiguration at `ConvertSdk.create`
  raises (an `ArgumentError`).
- **Ruby ≥ 3.1** — CRuby 3.1–3.4 and JRuby are supported.

## Install

```ruby
# Gemfile
gem "convert_sdk"
```

```sh
gem install convert_sdk
```

## 5-minute start

The complete flow — build a client, create a per-visitor context, decide an
experience, act on the result, track a conversion, and flush — in one
copy-pasteable block:

```ruby
require "convert_sdk"

# 1. Build ONE client at boot and reuse it for the life of the process.
#    (Fetch mode: pass an sdk_key. Direct-data mode: pass a pre-fetched `data:`.)
CONVERT_SDK = ConvertSdk.create(sdk_key: ENV.fetch("CONVERT_SDK_KEY"))

# 2. One context per visitor (per web request / per job). Cheap — no network,
#    no thread.
context = CONVERT_SDK.create_context("visitor-123", { "country" => "US" })

# 3. Decide an experience. Returns a BucketedVariation on a hit, or a Sentinel
#    on a miss — NEVER raises, NEVER a bare nil.
variation = context.run_experience("homepage-test")

# 4. Act on the result. `variation&.key` is the variation key on a hit and nil
#    on a miss (a Sentinel's #key is always nil), so a single `case` covers both.
case variation&.key
when nil           then render_default        # business miss — show the control
when "treatment"   then render_treatment
else                    render_variation(variation.key)
end

# 5. Track a conversion with revenue. Deduplicated per visitor per goal.
context.track_conversion("purchase", goal_data: { amount: 49.99, transaction_id: "tx-1" })

# 6. Flush queued events synchronously. In long-running servers the background
#    timer also drains; call flush explicitly before a process exits (Lambda/CLI).
CONVERT_SDK.flush
```

> **Production wiring per runtime** — Rails, Sidekiq, AWS Lambda, and plain CLI
> each have a copy-pasteable quickstart (every recipe is backed by an automated
> test): [Rails](docs/quickstart-rails.md) ·
> [Sidekiq](docs/quickstart-sidekiq.md) · [AWS Lambda](docs/quickstart-lambda.md)
> · [CLI](docs/quickstart-cli.md).

## Fork safety (zero config)

Fork safety is the SDK's flagship guarantee, so it leads the docs.

**The claim:** build the client once, let your server fork workers, and events
are delivered from every forked worker — **with zero fork-handling code in your
app.** No `postfork`, no `on_worker_boot` hook required.

**How it works:**

- At `require "convert_sdk"` the SDK installs a single `Process._fork` hook
  (its only global mutation). The hook is cheap and starts **no threads**.
- The SDK starts **no background threads until first use** — a client built in a
  preloading master (Puma `preload_app!`) carries no thread state across the
  fork.
- On the first decision in a forked worker, the `_fork` detection plus
  **PID-guarded** flush boundaries automatically re-arm the client (timers
  re-start lazily, the queue's process ownership resets) — so the worker decides
  and delivers on its own.

**When you need `postfork`:** only for setups that bypass `Process._fork`
entirely (or daemonize via `Process.daemon`), or if you prefer an explicit
re-arm (LaunchDarkly-style). The
[fork/daemon matrix in the troubleshooting guide](docs/troubleshooting.md#forkdaemon-matrix)
spells out exactly which runtimes are automatic and which need an explicit
`CONVERT_SDK.postfork` call. The four quickstarts ship the right wiring for each.

## Public API

Every method below is the **frozen public surface**. Full signatures and
semantics live in the [YARD API docs](https://convertcom.github.io/ruby-sdk).

### Factory

| Method | Purpose |
|--------|---------|
| [`ConvertSdk.create(sdk_key:, data:, store:, clock:, sink:, **options)`](https://convertcom.github.io/ruby-sdk/ConvertSdk.html#create-class_method) | Build a `Client`. Pass `sdk_key:` (live config fetch) or `data:` (pre-fetched config, no fetch). The only method that may raise (`ArgumentError` on misconfiguration). |

### `ConvertSdk::Client` — the process-lifetime handle

| Method | Purpose |
|--------|---------|
| [`#create_context(visitor_id = nil, attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Client.html#create_context-instance_method) | Create a new per-visitor `Context`. Returns `nil` for a blank visitor id. |
| [`#flush(reason = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Client.html#flush-instance_method) | Synchronously deliver queued events. Alias: `#release_queues`. |
| [`#postfork`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Client.html#postfork-instance_method) | Explicitly re-arm after a fork (rarely needed — see [Fork safety](#fork-safety-zero-config)). |
| [`#on(event, &block)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Client.html#on-instance_method) | Subscribe to a lifecycle event (`ready`, `config.updated`, `bucketing`, `conversion`). |

### `ConvertSdk::Context` — the per-visitor surface

| Method | Purpose |
|--------|---------|
| [`#run_experience(key, attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_experience-instance_method) | Decide one experience. Returns a `BucketedVariation` (hit) or `Sentinel` (miss). |
| [`#run_experiences(attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_experiences-instance_method) | Decide all running experiences. Returns an `Array<BucketedVariation>` (misses excluded). |
| [`#run_feature(key, attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_feature-instance_method) | Evaluate one feature flag with typed variables. Returns a `BucketedFeature` (or `Array`). |
| [`#run_features(attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_features-instance_method) | Evaluate all declared features. Returns an `Array<BucketedFeature>` (enabled + disabled). |
| [`#track_conversion(goal_key, goal_data: nil, force_multiple_transactions: false)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#track_conversion-instance_method) | Track a conversion (with optional revenue/transaction data), deduplicated per visitor per goal. |
| [`#set_default_segments(segments)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#set_default_segments-instance_method) | Attach default report-segments for the visitor. |
| [`#run_custom_segments(segment_keys, attributes = nil)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#run_custom_segments-instance_method) | Evaluate named custom segments and attach matching ids. |
| [`#update_visitor_properties(properties)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#update_visitor_properties-instance_method) | Merge sticky visitor properties (in-memory + store). |
| [`#get_visitor_data`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#get_visitor_data-instance_method) | Read the visitor's persisted `StoreData`. |
| [`#get_config_entity(key, entity_type)`](https://convertcom.github.io/ruby-sdk/ConvertSdk/Context.html#get_config_entity-instance_method) | Look up a config entity (`:experience` / `:feature` / `:goal`) by key. |

## The sentinel return contract

Decisioning methods **never raise** and **never return a bare `nil`** for a
business miss. They return a value object:

- A **hit** returns a frozen `BucketedVariation` (or `BucketedFeature`): `#key`
  is the real key, `#error?` is `false`.
- A **miss** returns a frozen `Sentinel`: `#key` is **always `nil`**, `#error?`
  is **always `true`**, and `#to_s` is the wire string.

This is why the documented branch pattern works for both cases at once:

```ruby
case (variation = context.run_experience("homepage-test")).key
when nil then render_default            # Sentinel — a business miss
else          render_variation(variation.key)
end
```

For features, branch on `#status` instead (a feature miss is a DISABLED
`BucketedFeature`, never a sentinel):

```ruby
feature = context.run_feature("new-checkout")
if feature.status == ConvertSdk::FeatureStatus::ENABLED
  render_new_checkout(feature.variables["headline"])
else
  render_legacy_checkout
end
```

## Configuration

Pass any of these as keyword options to `ConvertSdk.create`. Values are the
JS-parity defaults (verified against the JS/PHP reference SDKs) — they are not
tuning knobs and should not be changed without reason.

| Option | Default | Purpose |
|--------|---------|---------|
| `sdk_key` | `nil` | Account/project SDK key (fetch mode). At least one of `sdk_key` / `data` is required. |
| `sdk_key_secret` | `nil` | Bearer secret for config fetch. Redacted from all logs. |
| `data` | `nil` | Pre-fetched config object (direct-data mode); skips the fetch. |
| `environment` | `nil` | Platform environment selector (e.g. `"staging"`). |
| `config_endpoint` | `https://cdn-4.convertexperiments.com/api/v1` | Config-fetch base URL. |
| `track_endpoint` | `https://[project_id].metrics.convertexperiments.com/v1` | Event-tracking base URL. |
| `data_refresh_interval` | `300` | Config-refresh cadence (seconds). **`nil` = timer-off** (Lambda/CLI). |
| `flush_interval` | `1` | Event-flush cadence (seconds). **`nil` = timer-off** (Lambda/CLI). |
| `event_batch_size` | `10` | Events per delivery batch. |
| `max_traffic` | `10000` | Bucketing max traffic (JS-parity constant). |
| `hash_seed` | `9999` | Bucketing hash seed (JS-parity constant). |
| `keys_case_sensitive` | `true` | Rule-key case sensitivity. |
| `negation` | `"!"` | Rule negation token. |
| `log_level` | `ConvertSdk::LogLevel::DEBUG` | Logging threshold (`TRACE`=0 … `SILENT`=5). |
| `tracking` | `true` | Master switch for outbound event tracking. |
| `open_timeout` | `5` | HTTP connect timeout (seconds). |
| `read_timeout` | `10` | HTTP read timeout (seconds). |

An unknown option key raises `ArgumentError` at construction — a typo fails fast
rather than being silently ignored.

## Data stores

Sticky bucketing and goal deduplication persist through a **store** port. The
default is an in-process `MemoryStore`. For multi-process fleets (Puma clusters,
Sidekiq workers, Lambda) where state must be shared, pass a `RedisStore`:

```ruby
require "convert_sdk"

store = ConvertSdk::Stores::RedisStore.new(url: ENV.fetch("REDIS_URL"))
CONVERT_SDK = ConvertSdk.create(sdk_key: ENV.fetch("CONVERT_SDK_KEY"), store: store)
```

The `redis` gem is **your** dependency (lazily required only when a `RedisStore`
builds its own client) — it is never a runtime dependency of this gem. Any
object that duck-types `get`/`set` is accepted as a custom store.

## Documentation

- **Quickstarts:** [Rails](docs/quickstart-rails.md) ·
  [Sidekiq](docs/quickstart-sidekiq.md) · [AWS Lambda](docs/quickstart-lambda.md)
  · [CLI](docs/quickstart-cli.md)
- **[Troubleshooting](docs/troubleshooting.md)** — missing-events debugging, the
  fork/daemon matrix, and TRACE logging.
- **[Migrating from Kameleoon](docs/migrate-from-kameleoon.md)**
- **[API reference (YARD)](https://convertcom.github.io/ruby-sdk)**
- **[Contributing](CONTRIBUTING.md)**

## Development

```sh
bundle install        # install dev/test dependencies
bundle exec rake      # the default task: RSpec + RuboCop
bundle exec rbs -r net-http -r uri -r json -I sig validate   # validate RBS signatures
bundle exec steep check                                      # static type check
```

Publishing is handled exclusively by the OIDC release workflow — there is no
`rake release` task. See [CONTRIBUTING.md](CONTRIBUTING.md) for the release
process.

## License

Apache-2.0. See [LICENSE](LICENSE).
