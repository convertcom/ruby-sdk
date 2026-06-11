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

## Two modes — OFFLINE by default

The demo runs in one of two clearly-separated modes, selected by the **presence**
of credentials/endpoints (never a guess):

| Mode | Selected when | How the client is built | Network |
|------|---------------|-------------------------|---------|
| **OFFLINE** (default) | **NEITHER** `CONVERT_SDK_KEY` **NOR** `CONVERT_CONFIG_ENDPOINT` is set | `ConvertSdk.create(data: <committed fixture>)` — **direct-data mode** | **none** |
| **LIVE** (opt-in) | `CONVERT_SDK_KEY` is set | `ConvertSdk.create(sdk_key: …)` against the shared staging project | config GET + track POST |

OFFLINE mode reads a config fixture committed at
`config/convert_demo_config.json` (a byte-for-byte copy of the SDK's
`spec/fixtures/test-config.json`, account `10022898`). It needs **zero
credentials** and is **fully deterministic** — the same visitor always buckets
into the same variation (MurmurHash3, seed `9999`). This is what a human hitting
`docker compose up` with no `.env` gets, and what the per-URL table below
documents.

> The fork smoke (`script/fork_smoke.rb`) sets BOTH `CONVERT_SDK_KEY=smoke-sdk-key`
> and `CONVERT_CONFIG_ENDPOINT`/`CONVERT_TRACK_ENDPOINT` (its local stub), so it
> takes the LIVE/stub path — the OFFLINE default never interferes with it.

## What's here

| File | What it teaches |
|------|-----------------|
| `Gemfile` | Uses the SDK by `path: "../.."` — exercises the **real gemspec** (packaging mistakes surface here, not at publish). |
| `config/initializers/convert_sdk.rb` | **The recipe:** build ONE `CONVERT_SDK` client at boot; the OFFLINE/LIVE selector lives here. |
| `app/controllers/concerns/convert_context.rb` | **The recipe:** one `Context` per request, from the visitor id. |
| `app/controllers/demo_controller.rb` | The full loop: `run_experience` → `run_feature` → `run_custom_segments` → `track_conversion` → `flush`, rendered as HTML or JSON. |
| `app/views/demo/run.html.erb` | Bare semantic HTML (no CSS/JS/asset pipeline) — the DOM IS the verification surface. |
| `config/convert_demo_config.json` | The committed OFFLINE config fixture (direct-data mode). |
| `config/puma.rb` | `workers 2` + `preload_app!` — the production cluster shape. **No fork code.** |
| `script/fork_smoke.rb` | The release-blocking fork-safety smoke (see below). |

### The flagship claim: ZERO fork-handling code

There is **no** `postfork`, **no** `on_worker_boot { CONVERT_SDK.postfork }`, no
fork hook anywhere. The SDK installs a `Process._fork` hook at require time that
**automatically** re-arms the client in every forked worker on first use. The
belt-and-braces explicit re-arm exists and is documented in the SDK quickstart,
but it is **not needed** — and this demo's smoke test proves it.

## Run it — OFFLINE (default, zero credentials)

```bash
# Either Docker:
docker compose up                             # Docker Compose V2 — boots the Puma cluster

# Or local Ruby:
bundle install
bundle exec puma -C config/puma.rb
```

Then hit the endpoints:

```bash
curl "http://localhost:3000/pid"                            # which worker am I?  -> {"pid":NNNN}
curl "http://localhost:3000/demo?visitor_id=visitor-1"      # full loop, HTML (default)
curl -H 'Accept: application/json' \
     "http://localhost:3000/demo?visitor_id=visitor-1"      # full loop, JSON
curl -X POST "http://localhost:3000/flush"                  # force a synchronous flush
```

To see the SDK's internal decisioning lines on stdout, boot with
`CONVERT_LOG_LEVEL=trace` (attaches a stdlib `Logger` sink at TRACE; the
`sdk_key` is always redacted):

```bash
CONVERT_LOG_LEVEL=trace bundle exec puma -C config/puma.rb
```

### Stop it

The Puma **cluster master** runs until it receives a signal — it does **not** stop
when you close the terminal. Stop it the way you started it:

| You started it with | Stop it with |
|---------------------|--------------|
| `bundle exec puma …` in the **foreground** | **`Ctrl-C`** — sends `SIGINT` to the master, which gracefully stops both workers and frees the port. |
| `docker compose up` | **`Ctrl-C`**, then `docker compose down` to remove the container. |
| a **backgrounded or orphaned** process still holding the port | `lsof -ti tcp:3000 \| xargs kill` — finds every PID bound to `3000` (master + both workers) and stops them. |

> **Why this bites:** if you background the server (or close the terminal without
> `Ctrl-C`), the workers keep `tcp://0.0.0.0:3000` bound, and the **next**
> `bundle exec puma` dies with **`Address already in use`** (the very failure
> `config/puma.rb` warns about). Stopping the master reaps the workers and frees
> the port. Confirm it's free with `lsof -iTCP:3000 -sTCP:LISTEN` — **no output
> means free**.

### Per-URL verification table (OFFLINE mode, fixed visitor id `visitor-1`)

OFFLINE bucketing is **deterministic** — these exact values reproduce on every
boot. `GET /demo?visitor_id=visitor-1` renders the following (DOM ids shown; the
JSON shape via `Accept: application/json` carries the identical data):

| What | Rendered value (DOM id) | Notes |
|------|-------------------------|-------|
| Mode | `offline` (`#mode`) | direct-data, no network |
| Experience decision | `DECIDED` (`#experience-decided`) | `run_experience("test-experience-ab-fullstack-2")` |
| Experience id | `100218245` (`#experience-id`) | |
| Variation id | `100299457` (`#variation-id`) | |
| Variation key | `100299457-variation-1` (`#variation-key`) | |
| Feature key | `feature-1` (`.feature-key`) | `run_feature("feature-1")` resolves across BOTH carrying experiences (two `<article class="feature">` blocks) |
| Feature status | `enabled` (`.feature-status`) | |
| Feature variable `enabled` | `false` / `true` — type `FalseClass` / `TrueClass` (`.var-name`/`.var-value`/`.var-type`) | typed variables, cast type shown |
| Feature variable `caption` | `Not allowed` / `Allowed` — type `String` | |
| Attached custom segment | `200299434` (`#attached-segments .segment`) | `run_custom_segments(["test-segments-1"], { ruleData: { "enabled" => true } })` matches segment `200299434` |
| Conversion goal | `goal-without-rule` (`#goal-key`) | `track_conversion` with revenue `goal_data` |
| Conversion amount | `49.99` (`#conversion-amount`) | overridable via `CONVERT_DEMO_PURCHASE_AMOUNT` |

The rendered HTML (abbreviated) for `visitor_id=visitor-1`:

```html
<dd id="mode">offline</dd>
<dd id="visitor-id">visitor-1</dd>
<p id="experience-decided">DECIDED</p>
<dd id="experience-id">100218245</dd>
<dd id="variation-id">100299457</dd>
<dd id="variation-key">100299457-variation-1</dd>
<dd class="feature-key">feature-1</dd>
<dd class="feature-status">enabled</dd>
<li class="feature-variable"><span class="var-name">enabled</span> = <span class="var-value">false</span> (<span class="var-type">FalseClass</span>)</li>
<li class="feature-variable"><span class="var-name">caption</span> = <span class="var-value">Not allowed</span> (<span class="var-type">String</span>)</li>
<ul id="attached-segments"><li class="segment">200299434</li></ul>
<dd id="goal-key">goal-without-rule</dd>
<dd id="conversion-amount">49.99</dd>
```

### The SDK decision trace (captured at `CONVERT_LOG_LEVEL=trace`)

Booting OFFLINE with `CONVERT_LOG_LEVEL=trace` and hitting
`/demo?visitor_id=visitor-1` emits these lines verbatim (a stdlib `Logger`
prefixes `D, [...] DEBUG -- :` / `I, [...]  INFO -- :`; the SDK message follows).
The bucketing math is deterministic — `hash=2798063563` reproduces every run:

```
BucketingManager#value_visitor_based: experience_id="100218245" visitor_id="visitor-1" seed=9999 hash=2798063563 scaled=6514.749403577298 result=6514
BucketingManager#select_bucket: value=6514 redistribute=0 variation="100299457"
BucketingManager#bucket_for_visitor: experience_id="100218245" visitor_id="visitor-1" bucket_value=6514 selected_variation_id="100299457"
DataManager#match_rules_by_field: rules matched id=100218245
DataManager#retrieve_bucketing: bucketed exp=100218245 var=100299457
ApiManager#release_queue: queue released, reason=demo-request, visitors=1
```

`run_feature("feature-1")` resolves across both feature-carrying experiences, so
the trace also shows bucketing for `100218246` (→ `100299461`) and `100218247`
(→ no bucket). A successful first-touch segment match and a first conversion are
observable in the rendered DOM / JSON (segment id `200299434`; the conversion
event in the flushed payload); the SDK logs the segment/conversion only on the
re-store / dedup paths (`SegmentsManager#set_custom_segments: custom segment id
200299434 already stored`, `DataManager#convert: goal 100215962 already converted
— skipping (dedup)`), which you'll see on a SECOND request for the same visitor.

**Network:** OFFLINE makes **zero** HTTP requests — the config is the committed
fixture (direct-data mode) and the flush writes to the in-memory queue only.

### LIVE mode (opt-in — shared staging project)

```bash
cp .env.example .env          # then uncomment the LIVE block in .env
docker compose up
```

LIVE wires `ConvertSdk.create(sdk_key: "10035569/10034190")` against the shared
Convert **staging** project (the same one the JS/PHP demos use). That key needs
**no secret** (the SDK requires `sdk_key` OR `data`; the Story 5.1 staging suite
sends a secret only when one is set — the shared key has none). The controller's
LIVE entity-key defaults match the php-sdk demo's verified entities
(`test-experience-ab-fullstack-1`, `feature-5`, `test-segment-1`,
`button-primary-click`). LIVE makes a config **GET** (the SDK config endpoint) and
a track **POST** with the wire shape
`{accountId, projectId, enrichData, source, visitors:[{visitorId, events:[bucketing, conversion…]}]}`.

## The fork-safety smoke (release-blocking — NFR11)

`script/fork_smoke.rb` is **the test** (the demo is an app, so the smoke script —
not RSpec — is its verification). It runs **offline and deterministically**:

1. Starts a local **stdlib stub server** (no WEBrick/Rack dependency) that serves
   a canned config (`spec/fixtures/test-config.json`) and **records** the visitor
   ids in every tracked payload.
2. Boots the demo under the **real Puma cluster** with the SDK's `config_endpoint`
   and `track_endpoint` pointed at the stub (the SDK's Story 2.4 endpoint options
   — no test seam in lib code), timers off (each request flushes synchronously).
   Because it sets `CONVERT_SDK_KEY` + the endpoints, it uses the LIVE/stub path,
   **not** the OFFLINE direct-data default.
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
on `pull_request` and `push`. It is **release-blocking (NFR11)**.

> **Admin action:** add the fork-smoke check to the branch-protection **required
> status checks** for `main` so a fork-safety regression blocks merge.

## Testing & verification commands

Run from the demo directory unless noted. The first command is THIS demo's own
test; the rest are the gem's gates (run from the repo root) and are listed so the
demo's contributors can verify the whole surface.

| Command | Run from | What it enforces |
|---------|----------|------------------|
| `bundle exec ruby script/fork_smoke.rb` | `demo/rails` | The release-blocking fork-safety proof (≥ 2 worker PIDs deliver). |
| `bundle exec rspec` | repo root | Full unit/integration suite + the SimpleCov coverage gate (85% line). |
| `bundle exec rake` | repo root | The default task — `rspec` + `rubocop`. |
| `bundle exec rbs validate` | repo root | RBS signature validity (CRuby only). |
| `bundle exec steep check` | repo root | Static type check (CRuby only). |
| `DISABLE_COVERAGE=1 bundle exec rspec spec/cross_sdk` | repo root | Cross-SDK MurmurHash3 parity gate. |
| `bundle exec rspec spec/integration/full_chain_spec.rb` | repo root | Full-chain release gate (create → decide → track → flush, wire bytes, zero secret leakage). |

The demo itself is excluded from the gem package (`gemspec spec.files`) and from
the gem's RuboCop / SimpleCov / RBS / Steep gates — it's an app, not the lib.
