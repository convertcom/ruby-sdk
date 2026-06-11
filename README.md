# Convert Ruby SDK

[![Quality Checks](https://github.com/convertcom/ruby-sdk/actions/workflows/qa.yml/badge.svg)](https://github.com/convertcom/ruby-sdk/actions/workflows/qa.yml)
[![Gem Version](https://img.shields.io/gem/v/convert_sdk.svg)](https://rubygems.org/gems/convert_sdk)
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

> **Production wiring per runtime** — Rails, Sidekiq, AWS Lambda, and CLI recipes live in the wiki: [Fork Safety & Runtime Recipes](https://github.com/convertcom/ruby-sdk/wiki/ForkSafety) and [Quickstart](https://github.com/convertcom/ruby-sdk/wiki/Quickstart).

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
[fork/daemon matrix in the troubleshooting guide](https://github.com/convertcom/ruby-sdk/wiki/ForkSafety#forkdaemon-matrix)
spells out exactly which runtimes are automatic and which need an explicit
`CONVERT_SDK.postfork` call. The four quickstarts ship the right wiring for each.

## Public API

The full public API is documented in the wiki and the YARD API reference. The
entry point is `ConvertSdk.create` (factory); it returns a `Client` with
`#create_context`, `#flush`, `#postfork`, and `#on`. Each `Context` exposes
`#run_experience`, `#run_feature`, `#track_conversion`, and related methods.
See [Code Examples](https://github.com/convertcom/ruby-sdk/wiki/CodeExamples) and
the **[API reference (YARD)](https://convertcom.github.io/ruby-sdk)** for full
signatures.

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

All configuration options are passed as keyword arguments to `ConvertSdk.create`.
See the [Configuration wiki page](https://github.com/convertcom/ruby-sdk/wiki/Configuration)
for the full option table with defaults. Pass `data_refresh_interval: nil` and
`flush_interval: nil` for Lambda/CLI (timer-off mode).

## Data stores

Sticky bucketing and goal deduplication persist through a store port (default:
in-process `MemoryStore`). See
[Configuration](https://github.com/convertcom/ruby-sdk/wiki/Configuration) for
the `RedisStore` recipe and custom store duck-typing contract.

## Documentation

Full developer documentation lives in the **[Convert Ruby SDK wiki](https://github.com/convertcom/ruby-sdk/wiki)**:

- [Quickstart](https://github.com/convertcom/ruby-sdk/wiki/Quickstart) ·
  [Installation](https://github.com/convertcom/ruby-sdk/wiki/Installation) ·
  [Initialization](https://github.com/convertcom/ruby-sdk/wiki/Initialization)
- [Configuration](https://github.com/convertcom/ruby-sdk/wiki/Configuration) ·
  [Return Types & Sentinels](https://github.com/convertcom/ruby-sdk/wiki/ReturnTypes) ·
  [Code Examples](https://github.com/convertcom/ruby-sdk/wiki/CodeExamples)
- [Fork Safety & Runtime Recipes](https://github.com/convertcom/ruby-sdk/wiki/ForkSafety) ·
  [Tracking Control](https://github.com/convertcom/ruby-sdk/wiki/TrackingControl) ·
  [Testing](https://github.com/convertcom/ruby-sdk/wiki/Testing)
- Core concepts & how-to: bucketing algorithm, rule evaluation, running experiences (see the wiki sidebar)
- **[API reference (YARD)](https://convertcom.github.io/ruby-sdk)** — generated method-level docs
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
