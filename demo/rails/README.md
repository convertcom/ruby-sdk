# Convert Ruby SDK — Rails demo (with Puma-cluster fork-safety smoke)

A minimal Rails 7.2+ app that exercises the **entire** Convert SDK loop under the
standard production deployment shape — **Puma cluster** (`workers 2` +
`preload_app!`) — and proves the SDK's flagship claim:

> **Events tracked from BOTH forked Puma workers arrive at the track endpoint,
> with ZERO fork-handling code anywhere in the app.**

This directory is **teaching material** and the living example the SDK quickstart
references. It is **not** part of the published gem (the gemspec excludes every
`demo/` path) and is **not** subject to the gem's RuboCop / SimpleCov / RBS /
Steep gates (it's an app, not the lib).

## What's here

| File | What it teaches |
|------|-----------------|
| `Gemfile` | Uses the SDK by `path: "../.."` — exercises the **real gemspec** (packaging mistakes surface here, not at publish). |
| `config/initializers/convert_sdk.rb` | **The recipe:** build ONE `CONVERT_SDK` client at boot. |
| `app/controllers/concerns/convert_context.rb` | **The recipe:** one `Context` per request, from the visitor id. |
| `app/controllers/demo_controller.rb` | The full loop: `run_experience` → `run_feature` → `run_custom_segments` → `track_conversion` → `flush`. |
| `config/puma.rb` | `workers 2` + `preload_app!` — the production cluster shape. **No fork code.** |
| `script/fork_smoke.rb` | The release-blocking fork-safety smoke (see below). |

### The flagship claim: ZERO fork-handling code

There is **no** `postfork`, **no** `on_worker_boot { CONVERT_SDK.postfork }`, no
fork hook anywhere. The SDK installs a `Process._fork` hook at require time that
**automatically** re-arms the client in every forked worker on first use. The
belt-and-braces explicit re-arm exists and is documented in the SDK quickstart,
but it is **not needed** — and this demo's smoke test proves it.

## Run it interactively (live staging)

Wired to the shared Convert **staging** project (the same one the JS/PHP demos
use). Copy the env example and fill in the real keys:

```bash
cp .env.example .env          # then edit .env with the staging project's keys
docker compose up             # Docker Compose V2 — boots the Puma cluster
```

Then hit the endpoints:

```bash
curl "http://localhost:3000/pid"                          # which worker am I?
curl "http://localhost:3000/demo?visitor_id=alice"        # run the full loop
curl -X POST "http://localhost:3000/flush"                # force a flush
```

> **Entity keys.** `.env.example` lists the entity keys the demo flows need
> (`CONVERT_PRICING_EXPERIENCE_KEY`, `CONVERT_FEATURE_KEY`, `CONVERT_SEGMENT_KEY`,
> `CONVERT_GOAL_KEY`). They are **placeholders** — set them from the shared
> staging project (the same entities the JS/PHP demos exercise). They were not
> pinned to real values when this demo was authored (no live staging access in
> that environment).

## The fork-safety smoke (release-blocking — NFR11)

`script/fork_smoke.rb` is **the test** (the demo is an app, so the smoke script —
not RSpec — is its verification). It runs **offline and deterministically**:

1. Starts a local **stdlib stub server** (no WEBrick/Rack dependency) that serves
   a canned config (`spec/fixtures/test-config.json`) and **records** the visitor
   ids in every tracked payload.
2. Boots the demo under the **real Puma cluster** with the SDK's `config_endpoint`
   and `track_endpoint` pointed at the stub (the SDK's Story 2.4 endpoint options
   — no test seam in lib code), timers off (each request flushes synchronously).
3. Drives `GET /pid` + `GET /demo` requests with a visitor id of the form
   **`smoke-test-{pid}-{n}`**, where `{pid}` is the PID of the Ruby process
   (Puma worker) that served the request, until **≥ 2 distinct worker PIDs** have
   served.
4. **Asserts** the stub recorded tracked events whose visitor ids embed **≥ 2
   distinct PIDs** — proving both forked workers delivered, with zero fork code.

Every wait (worker boot, request, event arrival) is **timeout-bounded**; any
failure prints diagnostics and exits non-zero.

```bash
cd demo/rails
bundle install
bundle exec ruby script/fork_smoke.rb     # exits 0 on PASS, non-zero on FAIL
```

### Branch protection (required check)

The smoke runs as a **dedicated** CI workflow (`.github/workflows/demo-smoke.yml`)
on `pull_request` and `push`, named **"Demo Fork Smoke"**. It is **release-blocking
(NFR11)**. This adds a **new** required check, taking the PR's CI from 11 → 12
checks.

> **Admin action:** add **"Puma-cluster fork smoke (release-blocking)"** to the
> branch-protection **required status checks** for `main` so a fork-safety
> regression blocks merge.
