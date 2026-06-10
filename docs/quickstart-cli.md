# Quickstart: CLI / plain scripts

A plain Ruby script (a rake task, a cron job, a one-off CLI) builds a client,
decides, and exits. The SDK registers a **PID-guarded `at_exit` flush** that
fires automatically on **normal exit** — so a short script needs no explicit
flush.

## The recipe — automatic at_exit flush

<!-- Tested by: recipe "plain-cli-at-exit" in spec/integration/runtime_recipes_spec.rb -->

```ruby
# script.rb — the PID-guarded at_exit flush fires on normal exit.
require "convert_sdk"

CONVERT_SDK = ConvertSdk.create(sdk_key: ENV["CONVERT_SDK_KEY"])
ctx = CONVERT_SDK.create_context("cli-visitor")
ctx.run_experience("homepage-test")
# falls off the end -> at_exit flush delivers (NOT under SIGKILL)
```

The `at_exit` handler is **PID-guarded**: it flushes only in the process that
registered it, so a child created by a later `fork` never double-delivers the
parent's queue.

## When to flush explicitly

The automatic `at_exit` flush covers normal exit. Call `CONVERT_SDK.flush`
explicitly when:

- The script is **long-running** and you want events delivered before the end
  (or at checkpoints) rather than only at exit.
- The process may be terminated by `SIGKILL` or `exit!` (which skip `at_exit`),
  or daemonized via `Process.daemon` (which forks — see below).

```ruby
CONVERT_SDK.create_context("cli-visitor").track_conversion("job-complete")
CONVERT_SDK.flush # deliver now, don't wait for at_exit
```

## Daemonized scripts (`Process.daemon`)

`Process.daemon` **forks** and exits the parent, so a client built **before**
`Process.daemon` lives on in the forked daemon. Call `CONVERT_SDK.postfork`
after daemonizing (or build the client after `Process.daemon`) so the daemon
re-arms in its own process:

```ruby
Process.daemon(true)
CONVERT_SDK.postfork   # re-arm in the daemonized process
```

See the [fork/daemon matrix](troubleshooting.md#forkdaemon-matrix) for the full
runtime breakdown.
