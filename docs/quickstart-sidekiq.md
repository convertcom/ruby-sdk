# Quickstart: Sidekiq

Sidekiq (OSS) is **threaded and single-process** — no fork. Build one client at
boot, reuse it across all job threads, and flush the remaining queue on
shutdown.

## 1. Build one client at boot

```ruby
# config/initializers/convert_sdk.rb
require "convert_sdk"

CONVERT_SDK = ConvertSdk.create(sdk_key: ENV.fetch("CONVERT_SDK_KEY"))
```

## 2. Use the singleton from jobs

Each job creates its own `Context` from the shared client. Contexts are
independent and thread-safe to create concurrently across worker threads.

```ruby
class ConversionJob
  include Sidekiq::Job

  def perform(visitor_id, attributes = {})
    context = CONVERT_SDK.create_context(visitor_id, attributes)
    context.run_experience("homepage-test")
    context.track_conversion("signup")
  end
end
```

The background flush timer delivers events while the process is alive. The one
thing to add is a **shutdown flush** so events still queued when Sidekiq stops
are delivered before the process exits.

## 3. Flush on shutdown

<!-- Tested by: recipe "sidekiq-shutdown-flush" in spec/integration/runtime_recipes_spec.rb -->

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.on(:shutdown) { CONVERT_SDK.flush }
end
```

`CONVERT_SDK.flush` (alias `release_queues`) drains the queue synchronously, so
the in-flight events from every job thread are delivered before the worker
process terminates.

> Running Sidekiq Enterprise with **forking** (multi-process) instead of pure
> threads? Then it behaves like a forking server — see the
> [fork/daemon matrix](troubleshooting.md#forkdaemon-matrix); automatic
> detection still applies, with `CONVERT_SDK.postfork` available as the explicit
> belt-and-braces re-arm.
