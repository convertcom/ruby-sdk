# Quickstart: AWS Lambda

AWS Lambda **freezes the execution environment** between invocations, so
background threads are useless (they may never run) and harmful (they can hold
events that never get delivered). The recipe is **timer-off mode** plus a
**synchronous flush before the handler returns**.

## Timer-off mode + synchronous flush

Disable both timers by passing `data_refresh_interval: nil` and
`flush_interval: nil`. In timer-off mode the SDK starts **zero background
threads**; config freshness is checked on-demand at decision time, and delivery
happens only when you call `flush` explicitly.

<!-- Tested by: recipe "aws-lambda-sync-flush" in spec/integration/runtime_recipes_spec.rb -->

```ruby
# handler.rb — timers OFF; flush synchronously before the handler returns.
require "convert_sdk"

CONVERT_SDK = ConvertSdk.create(sdk_key: ENV["CONVERT_SDK_KEY"],
                                data_refresh_interval: nil, flush_interval: nil)

def handler(event:, context:)
  ctx = CONVERT_SDK.create_context(event["visitorId"])
  variation = ctx.run_experience("homepage-test")
  CONVERT_SDK.flush # MUST be synchronous — the env freezes after return
  { variation: variation.key }
end
```

Building the client **outside** the handler (at module load) reuses it across
warm invocations, which is what you want — no per-invocation client
construction, and no threads to leak across the freeze boundary.

## Why synchronous flush is mandatory

The PID-guarded `at_exit` flush the SDK registers is best-effort and does **not**
run when the environment is frozen or killed (`SIGKILL`) — which is exactly what
Lambda does between invocations. So a synchronous `CONVERT_SDK.flush` before the
handler returns is the only reliable delivery point. Skipping it means events sit
in the queue until the next (possibly never) invocation.

See the [fork/daemon matrix](troubleshooting.md#forkdaemon-matrix) for how Lambda
compares to the forking and threaded runtimes.
