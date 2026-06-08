# Troubleshooting

The SDK is built to **never crash your host** — every public method degrades to
a documented return value and a log line instead of raising. That means failures
are silent by design, so debugging is mostly about **turning on logging** and
checking the **fork/daemon wiring** for your runtime.

## Missing events — decision tree

You decided an experience or tracked a conversion, but nothing arrived at the
track endpoint. Work down this list:

1. **Did you flush?** In short-lived processes (Lambda, CLI, rake tasks) events
   sit in the queue until a flush. Lambda **must** call `CONVERT_SDK.flush`
   synchronously before the handler returns; a CLI relies on the `at_exit`
   flush, which does **not** run under `SIGKILL` / `exit!`. See the
   [AWS Lambda](quickstart-lambda.md) and [CLI](quickstart-cli.md) quickstarts.
2. **Are you in a forked worker that didn't re-arm?** This is the most common
   cause. Check the [fork/daemon matrix](#forkdaemon-matrix) below — if your
   runtime needs an explicit `CONVERT_SDK.postfork` and you didn't call it, the
   forked worker's queue/timers are still owned by the parent process and never
   deliver.
3. **Is tracking disabled?** `ConvertSdk.create(tracking: false)` (global) or a
   per-call `attributes[:enable_tracking] => false` suppresses the outbound
   bucketing enqueue. The decision still happens and sticky data is still
   written — only delivery is suppressed. A `debug` line records each
   suppression.
4. **Was it a business miss?** `run_experience` returning a `Sentinel`
   (`variation.error? == true`, `variation.key == nil`) is a *miss*, not a bug —
   no bucketing event fires on a miss. Likewise `track_conversion` is a no-op
   when the goal is unknown or the conversion was deduplicated.
5. **Did the queue overflow?** The event queue is bounded at **1000 events** and
   drops the **oldest** on overflow, emitting a `warn` line (see
   [Queue-cap warning](#queue-cap-warning)). A sustained burst without a flush
   can drop events.
6. **Turn on TRACE logging** (next section) and read the fork / thread / queue /
   delivery lines.

## TRACE logging

The SDK logs through a multi-sink, level-gated `LogManager`. Levels are
`TRACE`(0) · `DEBUG`(1) · `INFO`(2) · `WARN`(3) · `ERROR`(4) · `SILENT`(5); a
message emits when its level is `>=` the configured threshold. Set the threshold
with `log_level:` and attach a sink at construction with `sink:`:

```ruby
require "convert_sdk"
require "logger"

CONVERT_SDK = ConvertSdk.create(
  sdk_key:   ENV.fetch("CONVERT_SDK_KEY"),
  log_level: ConvertSdk::LogLevel::TRACE,   # finest-grained
  sink:      Logger.new($stdout)            # any stdlib-Logger-compatible object
)
```

Passing `sink:` at `create` time (rather than attaching one afterward) is what
makes the **construction-time** lines observable — including the initial config
fetch.

### What to look for at TRACE / DEBUG

| Line fragment | What it tells you |
|---------------|-------------------|
| `installed direct data config` / `installed fetched config` | Config loaded successfully (the SDK is `ready`). |
| `config fetch failed (status …); continuing without config` | The fetch failed; the client is running config-less and decisions will miss. |
| `run_at_exit_flush: registering process exiting, flushing` | The PID-guarded `at_exit` flush fired on normal exit. |
| `run_at_exit_flush: suppressed in forked child (pid mismatch)` | A forked child correctly did **not** double-flush the parent's queue. |
| `tracking disabled, event suppressed` / `tracking suppressed for call` | Delivery was suppressed by the global or per-call tracking switch (see step 3). |
| `queue full, dropping oldest event` | The 1000-event cap was hit (see below). |

### Stdlib `Logger` wiring

Any object that responds to `debug`/`info`/`warn`/`error` is a valid sink — the
stdlib `Logger` qualifies directly. Note that `TRACE` and `DEBUG` both dispatch
to the sink's `#debug` method (stdlib `Logger` has no `trace`); the **numeric
level**, not the sink method, decides whether the line emits.

```ruby
logger = Logger.new("log/convert.log")
logger.level = Logger::DEBUG
CONVERT_SDK = ConvertSdk.create(sdk_key: ENV.fetch("CONVERT_SDK_KEY"),
                                log_level: ConvertSdk::LogLevel::TRACE, sink: logger)
```

You can fan out to multiple sinks (e.g. stdout **and** a file) by attaching more
than one — secrets (the `sdk_key` / `sdk_key_secret`) are redacted from every
line before any sink sees it.

## Fork/daemon matrix

The SDK installs a `Process._fork` hook at `require` time and PID-guards its
flush boundaries, so most runtimes are **automatic**. The exceptions are setups
that bypass `Process._fork` or where you want an explicit, deterministic re-arm.

| Runtime | Forks? | Automatic re-arm? | Explicit `postfork` needed? | Wiring |
|---------|--------|-------------------|-----------------------------|--------|
| **Puma cluster** (`preload_app!`) | Yes | ✅ Yes | No (belt-and-braces optional) | [quickstart-rails](quickstart-rails.md) |
| **Unicorn** | Yes | ✅ Yes | No (`after_fork` belt-and-braces) | [quickstart-rails](quickstart-rails.md#other-rack-servers-unicorn--passenger) |
| **Passenger** | Yes | ✅ Yes | No (`starting_worker_process` belt-and-braces) | [quickstart-rails](quickstart-rails.md#other-rack-servers-unicorn--passenger) |
| **Sidekiq** (OSS, threaded) | No | n/a (no fork) | No — add a shutdown **flush** | [quickstart-sidekiq](quickstart-sidekiq.md) |
| **AWS Lambda** | No | n/a (env freezes) | No — **timers off + sync flush** | [quickstart-lambda](quickstart-lambda.md) |
| **Plain CLI** | No | n/a | No — `at_exit` flush is automatic | [quickstart-cli](quickstart-cli.md) |
| **`Process.daemon`** | **Yes** | ⚠️ Not guaranteed | **Yes — call `postfork` after daemonizing** | [quickstart-cli](quickstart-cli.md#daemonized-scripts-processdaemon) |

**The `Process.daemon` edge case.** `Process.daemon` forks and exits the parent,
then detaches. A client built **before** `Process.daemon` lives on in the
daemonized child, which may never reach a flush boundary that triggers automatic
detection in time. The fix is explicit:

```ruby
Process.daemon(true)
CONVERT_SDK.postfork   # re-arm in the daemonized process
```

(Or build the client **after** `Process.daemon`.)

`postfork` delegates to the same re-arm path as automatic detection: it marks
the timers dead (they re-start lazily on next use), clears the queue's process
ownership, and resets the owning PID. It is idempotent and never raises.

## Queue-cap warning

The outbound event queue is **bounded at 1000 events** to protect host memory
under a sustained burst with no flush. On overflow it drops the **oldest** event
(not the newest) and logs:

```
WARN  VisitorsQueue#enqueue: queue full, dropping oldest event
```

If you see this line, you are enqueuing faster than you are flushing. Either
flush more often (e.g. lower `flush_interval`, or call `flush` explicitly at
checkpoints) or reduce the event volume.

## "Events vanish" — the ConvertAgent User-Agent guarantee

The Convert track endpoint silently drops any request whose `User-Agent` is not
`ConvertAgent/1.0`. **This never affects you:** the SDK's HTTP port applies that
exact `User-Agent` **last**, so it is unoverridable — even if you somehow set a
custom UA, the SDK's value wins on the wire. So a missing-events problem is never
a UA problem; work the [decision tree](#missing-events--decision-tree) above.
