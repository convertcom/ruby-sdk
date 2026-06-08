# Contributing to the Convert Ruby SDK

Thanks for contributing. This guide covers the dev setup, the conventions CI
enforces, the test layout, and how releases happen.

## Development setup

Requires Ruby ≥ 3.1 (the gem supports CRuby 3.1–3.4 and JRuby).

```sh
bundle install        # install dev/test dependencies
bundle exec rake      # the default task: RSpec + RuboCop
```

Type checking (RBS + Steep) lives in a separate Gemfile group so the JRuby
matrix leg can skip the C-extension build:

```sh
bundle exec rbs -r net-http -r uri -r json -I sig validate   # validate RBS signatures
bundle exec steep check                                      # static type check
```

The gem has **zero runtime dependencies** by design (stdlib only). Adding a
runtime dependency is an architecture change, not a routine PR — discuss it
first. All dev/test gems live in the `Gemfile`.

## Conventions CI enforces

The **Quality Checks** workflow (`.github/workflows/qa.yml`) gates every PR:

- **RuboCop** — `bundle exec rubocop` must pass (config in `.rubocop.yml`).
  Notably: frozen-string-literal magic comment on every file, double-quoted
  strings, 120-char lines.
- **RBS + Steep** — signatures in `sig/` must validate and type-check against
  `lib/`.
- **RSpec** — the full suite runs on the CRuby 3.1–3.4 + JRuby matrix, with
  coverage gates (see below).
- **Cross-SDK parity** — the 75-vector MurmurHash3 parity suite must pass 100%
  (a byte-identical-bucketing release gate).
- **Full-chain + gem-smoke + demo fork-smoke** — end-to-end release gates.

### Conventional Commits + squash merge

This repo is **squash-merge only**, so the **PR title** becomes the squash commit
subject — and CI validates it as a [Conventional Commit](https://www.conventionalcommits.org/):

```
<type>(<scope>)?!?: <description>
```

Allowed types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`,
`chore`. A `feat` or `fix` (or a `!` breaking-change marker) drives the next
release version (see below), so title accuracy matters.

Examples:

```
feat(context): add run_features bulk evaluation
fix(api): retain queue on a failed flush POST
docs(readme): document the sentinel return contract
```

### Coverage gates

Coverage is single-sourced in `spec/spec_helper.rb` (do not declare thresholds
elsewhere). The global floor is 85% line coverage; the critical algorithm units
(Hashing, Bucketing, Rules) require ≥ 95% line **and** branch coverage. Coverage
runs on CRuby only — the JRuby leg runs the suite without the gate.

## Test layout

| Directory | What lives there |
|-----------|------------------|
| `spec/unit/` | Per-class unit specs (mock collaborators, isolated logic). |
| `spec/integration/` | End-to-end specs: `full_chain_spec.rb` (the release-blocking create→decide→track→flush loop), `runtime_recipes_spec.rb` (the runtime-lifecycle recipes the quickstarts are transcribed from), `fork_safety_spec.rb`, `factory_wiring_spec.rb`. |
| `spec/cross_sdk/` | The cross-SDK MurmurHash3 parity vectors (the byte-identical bucketing proof). |
| `spec/docs/` | Docs-snippet smoke specs — run the README/quickstart code samples against the real gem so documentation never drifts. |
| `spec/staging/` | The live-platform suite (runs on schedule/dispatch only, never in PR CI). |
| `spec/support/` | Shared helpers (e.g. `runtime_recipe_helpers.rb`, which co-locates the recipe wiring snippets the quickstarts ship). |
| `spec/fixtures/` | Vendored config fixtures (`test-config.json`). |
| `demo/rails/` | The living Rails example app + fork-safety smoke (an app, not the lib — excluded from gem/RuboCop/coverage gates). |

When adding a documented code sample, **copy it from a working spec or the demo**
and add it to the `spec/docs/` smoke spec — never ship doc-only code that can
drift from the real gem.

## API documentation (YARD)

All public classes and methods are YARD-documented; `@api private` internals are
excluded from the published docs (`.yardopts` sets `--no-private`). Build the
docs locally with:

```sh
bundle exec yard doc                 # output to doc/
bundle exec yard stats --list-undoc  # audit the public surface
```

The published docs deploy to [GitHub Pages](https://convertcom.github.io/ruby-sdk)
on every push to `main` (`.github/workflows/pages.yml`).

## Releases

Releases are **fully automated** and run only from `main` — there is **no**
`rake release` task (it is deliberately absent from the `Rakefile`). The release
pipeline (semantic-release, configured in Story 5.4's `release.yml`) reads the
merged Conventional Commit subjects since the last release, computes the next
semantic version, tags it, and publishes the gem to RubyGems via OIDC. The
changelog is **GitHub Releases** (there is no `CHANGELOG.md` in the repo).

You never bump the version or publish manually — write an accurate PR title and
the pipeline does the rest on merge.
