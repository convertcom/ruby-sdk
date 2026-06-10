# Quickstart: Rails (Puma cluster)

This is the standard production deployment shape for Rails: **Puma in cluster
mode** (`workers N` + `preload_app!`). The Convert SDK is **fork-safe with zero
configuration** under this shape — build one client at boot and every forked
worker delivers events automatically.

> A complete, runnable version of this recipe lives in
> [`demo/rails/`](../demo/rails/) — a minimal Rails app wired to a Puma cluster
> with a release-blocking fork-safety smoke test. It is the living example this
> quickstart is transcribed from.

## 1. Build one client at boot

Create a single client in an initializer and assign it to a top-level constant.
Under `preload_app!` this runs **once** in the preloading master; every forked
worker inherits the already-built client.

```ruby
# config/initializers/convert_sdk.rb
require "convert_sdk"

CONVERT_SDK = ConvertSdk.create(
  sdk_key: ENV.fetch("CONVERT_SDK_KEY"),
  sdk_key_secret: ENV["CONVERT_SDK_KEY_SECRET"]
)
```

## 2. One context per request

A `Context` is the per-visitor decisioning surface. It is cheap to create per
request (no network, no thread) — the singleton client owns all shared state.

```ruby
# app/controllers/concerns/convert_context.rb
module ConvertContext
  extend ActiveSupport::Concern

  private

  def convert_context
    @convert_context ||= CONVERT_SDK.create_context(convert_visitor_id, convert_visitor_attributes)
  end

  def convert_visitor_id
    # A real app reads a first-party cookie here.
    cookies[:convert_visitor_id].presence || "anon-#{SecureRandom.hex(8)}"
  end

  def convert_visitor_attributes
    { "country" => request.headers["CF-IPCountry"] || "US" }
  end
end
```

```ruby
# app/controllers/pricing_controller.rb
class PricingController < ApplicationController
  include ConvertContext

  def show
    variation = convert_context.run_experience("pricing-test")
    case variation&.key
    when nil      then render :pricing_control     # business miss
    when "annual" then render :pricing_annual
    else               render :pricing_control
    end

    convert_context.track_conversion("view-pricing")
  end
end
```

The background flush timer drains events automatically in a long-running Puma
server, so you do **not** need to call `flush` per request.

## 3. Puma cluster config — zero fork code needed

The automatic `Process._fork` detection re-arms each worker on first use, so the
default config needs **nothing** added. For belt-and-braces (or for setups you
want to be explicit about), the optional re-arm is a single line in the
worker-boot hook.

<!-- Tested by: recipe "rails-puma-cluster" in spec/integration/runtime_recipes_spec.rb -->

```ruby
# config/puma.rb — automatic fork detection needs NOTHING; the optional
# belt-and-braces re-arm is one line in the worker-boot hook.
preload_app!
on_worker_boot { CONVERT_SDK.postfork }
```

> The `on_worker_boot { CONVERT_SDK.postfork }` line is **optional** — the SDK
> detects the fork automatically. The [`demo/rails/`](../demo/rails/) app proves
> delivery from both forked workers with **no** fork code at all.

## Other Rack servers (Unicorn / Passenger)

Unicorn and Passenger fork the same way Puma does, and automatic detection
covers them too. If you prefer an explicit re-arm, both expose a post-fork hook
— and the hook body is identical (`CONVERT_SDK.postfork`).

<!-- Tested by: recipe "unicorn-passenger-after-fork" in spec/integration/runtime_recipes_spec.rb -->

```ruby
# config/unicorn.rb (Passenger: PhusionPassenger.on_event(:starting_worker_process))
preload_app true
after_fork { |_server, _worker| CONVERT_SDK.postfork }
```

For Passenger, place the same `CONVERT_SDK.postfork` call inside
`PhusionPassenger.on_event(:starting_worker_process) { |_| CONVERT_SDK.postfork }`.

See the [fork/daemon matrix](troubleshooting.md#forkdaemon-matrix) for the full
runtime breakdown of what is automatic versus what needs an explicit `postfork`.
