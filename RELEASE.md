# Release Process

This document describes how releases of the Convert Ruby SDK (`convert_sdk`) are
produced and what must be configured before the release pipeline can run.

The short version: **every push to `main` whose Conventional Commit history
contains a `feat:`, `fix:`, `refactor:`, or a `BREAKING CHANGE` triggers a new
release.** The release workflow runs `semantic-release`, which writes the next
version into `lib/convert_sdk/version.rb` (a build-time, **uncommitted**
working-tree edit), builds and pushes the gem to RubyGems.org via **OIDC Trusted
Publishing**, then creates the `vX.Y.Z` git tag and a GitHub Release with the
generated notes.

No manual version bumping. No manual publishing. No long-lived RubyGems API key.
Conventional commits drive everything, and there is **no `rake release` task** —
publishing happens only through the OIDC `release.yml` workflow.

---

## Release Chain Overview

```
PR merged to main (squash merge → PR title becomes the commit subject)
  -> "Quality Checks" workflow runs (lint, typecheck, matrix RSpec, parity,
     full-chain, gem-smoke)
  -> "Release" workflow triggers via workflow_run AFTER Quality Checks succeeds
     (and only when the triggering event was a push to main)
    -> rubygems/configure-rubygems-credentials exchanges the workflow's OIDC
       token for a short-lived RubyGems credential
    -> semantic-release analyzes commits since the last v* tag:
      1. @semantic-release/commit-analyzer          → compute next version
      2. @semantic-release/release-notes-generator   → render markdown notes
      3. @semantic-release/exec (prepareCmd)         → write version into
                                                       lib/convert_sdk/version.rb
                                                       (UNCOMMITTED working-tree edit)
      4. @semantic-release/exec (publishCmd)         → gem build + gem push
                                                       to RubyGems.org
      5. @semantic-release/github                    → push vX.Y.Z tag + create
                                                       GitHub Release (via API)
```

The pipeline is **tag-only** — it pushes **no commit** to `main`. semantic-release
core pushes only the `vX.Y.Z` tag (a `refs/tags/*` ref, which the `main` branch
ruleset does not gate), and `@semantic-release/github` creates the Release via
the GitHub API. The version write in `lib/convert_sdk/version.rb` is a build-time
working-tree edit consumed by `gem build` and is **never committed**; the next
release derives its version from this run's git tag.

The plugin order above is **load-bearing** (defined in `release.config.mjs`).
**Publish-before-Release:** step 4 (`gem push`) runs before step 5 (the GitHub
Release). If `gem push` fails, semantic-release aborts **before** the tag and
Release are finalized — there is never a GitHub Release without a corresponding
gem on RubyGems.org. The repo stays in its pre-release state and the next push
retries.

This release flow uses no `@semantic-release/git` and no
`@semantic-release/changelog` plugins (deliberately forbidden — they would commit
to `main` and ship a committed `CHANGELOG.md`). The changelog lives on **GitHub
Releases** (the gemspec's `changelog_uri` points there).

---

## Versioning & Conventional-Commit Map

semantic-release computes the next version with the standard
`@semantic-release/commit-analyzer` (`conventionalcommits` preset). Only the
following commit types influence a release; everything else is a no-release:

| Commit type | Release type | In release notes |
|---|---|---|
| `fix:` | patch | Yes (Bug Fixes) |
| `feat:` | minor | Yes (Features) |
| `refactor:` | (per preset) | Yes (Refactoring) |
| `BREAKING CHANGE:` footer / `!` marker | **major** | Yes |
| `chore:`, `docs:`, `ci:`, `test:`, `style:`, `perf:` | no release | No (hidden) |

The release-notes generator surfaces only `feat` / `fix` / `refactor` sections;
the maintenance types (`chore`, `docs`, `ci`, `test`, `style`, `perf`) are marked
hidden in `release.config.mjs` and never appear in the notes.

All tags use the `v` prefix (`v1.0.0`, `v1.2.3`) — `tagFormat: 'v${version}'`.

---

## One-Time Setup (Repo Admin)

These steps must be completed **before the first merge to `main`** that should
publish, otherwise the release workflow will fail.

### 1. Register the RubyGems Trusted Publisher (OIDC)

RubyGems OIDC Trusted Publishing lets the release workflow authenticate with a
short-lived, exchanged credential instead of a long-lived API key. Register the
trusted publisher on RubyGems.org once:

1. Sign in at <https://rubygems.org>.
2. Create (or claim) the gem `convert_sdk` if it does not exist yet (the first
   `gem push` can also create it once trusted publishing is wired — but the
   trusted-publisher entry must exist first).
3. Go to the gem's settings → **Trusted publishers** → **Add a new publisher**
   (GitHub Actions), and enter:
   - **Repository:** `convertcom/ruby-sdk`
   - **Workflow filename:** `release.yml`
   - (Optional) environment: leave blank — the workflow uses no GitHub
     Environment.
4. Save. From then on, the `release.yml` workflow running on
   `convertcom/ruby-sdk` is trusted to publish `convert_sdk` with no stored API
   key.

There is **no `RUBYGEMS_API_KEY` secret anywhere** — the
`rubygems/configure-rubygems-credentials@v2.0.0` step in `release.yml` performs
the OIDC token exchange at run time. This is the Ruby-specific divergence from
the PHP SDK (whose `release.yml` carries only `contents: write`); ours also needs
`id-token: write`.

### 2. Enable GitHub Pages (API docs)

The YARD API docs deploy to GitHub Pages on every push to `main`
(`.github/workflows/pages.yml`). Enable Pages once:

1. Repo → **Settings** → **Pages**.
2. Set **Source** to **GitHub Actions**.

The published docs site is `https://convertcom.github.io/ruby-sdk` (the gemspec's
`documentation_uri`).

### 3. Repository secrets

| Secret | Required | Source |
|---|---|---|
| `GITHUB_TOKEN` | yes (auto) | Provided automatically by GitHub Actions for every run — nothing to configure. Used by semantic-release core to push the `vX.Y.Z` tag and by `@semantic-release/github` to create the Release. |

That is the **complete** secret list. RubyGems authentication is handled by OIDC
Trusted Publishing (step 1), so no RubyGems API-key secret is stored. The
workflow's only declared permissions are `contents: write` (tag + Release) and
`id-token: write` (OIDC exchange).

### 4. Branch-protection required checks

Configure branch protection on `main` (Repo → **Settings** → **Branches** →
add/edit the `main` rule) to require these status checks to pass before merge.
The names below are the **exact job names** from the workflows — quote them
verbatim:

From the **Quality Checks** workflow (`.github/workflows/qa.yml`):

- `PR title (Conventional Commits)`
- `Lint (RuboCop)`
- `Typecheck (RBS + Steep)`
- `Test (3.1)`, `Test (3.2)`, `Test (3.3)`, `Test (3.4)`, `Test (jruby)`
- `Cross-SDK parity (MurmurHash3)` — **release-blocking** (100% of the vendored
  MurmurHash3 vectors must pass)
- `Full-chain release gate` — **release-blocking** (the end-to-end
  create→decide→track→flush loop, exact wire bytes, zero secret leakage)
- `Gem build / install / require smoke`

From the **Demo Fork Smoke** workflow (`.github/workflows/demo-smoke.yml`, a
structurally independent workflow):

- `Puma-cluster fork smoke (release-blocking)` — **release-blocking** (events
  from ≥ 2 distinct forked Puma workers reach the track endpoint)

The two release-blocking gates and the fork-smoke gate must be in the required
set so a hashing/wiring/fork-safety regression can never reach a published gem.

---

## Triggering a Release

Releases are fully automatic. The process:

1. Open a PR containing one or more conventional commits. This repo is
   **squash-merge only**, so the **PR title** becomes the squash commit subject
   and must itself be a valid Conventional Commit (CI validates it).
2. Merge the PR to `main`. GitHub fires the **Quality Checks** workflow
   (`.github/workflows/qa.yml`).
3. On Quality Checks success, GitHub fires the **Release** workflow
   (`.github/workflows/release.yml`) via a `workflow_run` trigger
   (`workflows: ['Quality Checks']`, `branches: [main]`).
4. semantic-release analyzes every commit on `main` since the last `v*` tag and
   applies the version/notes map above.
5. If a release-worthy commit exists, it writes the version into
   `lib/convert_sdk/version.rb`, runs `gem build convert_sdk.gemspec && gem push
   convert_sdk-*.gem`, then pushes the `vX.Y.Z` tag and creates the GitHub
   Release. If nothing is release-worthy (only `chore`/`docs`/`ci`/`test`/…),
   the workflow succeeds silently with no release.

**No manual publish step.** You never bump the version or run `gem push` by hand
— write an accurate PR title and the pipeline does the rest on merge.

---

## Previewing a Release: Dry Run

`yarn release:dry-run` runs semantic-release in dry-run mode
(`semantic-release --dry-run --no-ci`). It will:

- Analyze commits since the last tag.
- Decide the next version.
- Show the rendered release notes.
- **Not** write `version.rb`, **not** build or push the gem, **not** tag.

semantic-release checks the current branch against the `branches` entry in
`release.config.mjs` (currently `['main']`). On `main`, the dry-run prints the
next-version plan. On any other branch it exits with:

```
This test run was not triggered in a known release branch
```

That message is **expected** — it confirms the config parses. To exercise a full
dry-run on a feature branch, temporarily add the branch name to
`release.config.mjs`'s `branches` array, run the dry-run, then discard the
temporary edit before committing:

```bash
# On main:
yarn release:dry-run

# On a feature branch (full dry-run):
# 1. Edit release.config.mjs → branches: ['main', 'feature/my-branch']
# 2. yarn release:dry-run
# 3. discard the temporary edit to release.config.mjs (do NOT commit it)
```

The branch must exist on `origin` (semantic-release needs `git ls-remote`); push
first if it is local-only.

---

## First Release (v1.0.0)

The first release is produced automatically by the pipeline — no manual tagging.
On the first merge to `main` after the release workflow is configured,
semantic-release observes that no prior `v*` tag exists, so it:

1. Treats every releasable commit in history (all `feat:` / `fix:` / `refactor:`
   / `BREAKING CHANGE` since project inception) as part of the first release.
2. Emits `v1.0.0` as the version (semantic-release's fixed first-release
   default).
3. Generates a release-notes block covering the full history, grouped by commit
   type.
4. Writes `1.0.0` into `lib/convert_sdk/version.rb` (uncommitted), runs `gem
   build` + `gem push`, then pushes the `v1.0.0` tag and publishes a GitHub
   Release on it.

`lib/convert_sdk/version.rb` ships with `VERSION = "0.0.0"` as a dev placeholder
— the first release overwrites it at build time (and never commits the change).
Do **not** create a `v1.0.0` tag manually before or after the first merge — the
pipeline owns this, and a pre-existing tag will be raced or block the automated
tag push.

---

## Fork-PR Safeguard (DO NOT REMOVE)

The release workflow's `if:` guard carries two conditions, both required:

```yaml
if: >
  github.event.workflow_run.conclusion == 'success' &&
  github.event.workflow_run.event == 'push'
```

The **second** condition — `github.event.workflow_run.event == 'push'` — is
critical. `workflow_run` fires on every completed Quality Checks run, including
runs triggered by pull requests. Fork PRs run with no secret/OIDC access, so
without this guard a fork PR's Quality Checks run would also fire the release
workflow, which would either:

1. Fail noisily (no OIDC token to exchange), cluttering the PR with red
   cross-marks, or — worse —
2. Under certain misconfigurations, leak into the PR's logs.

Always keep the `push` check. If you are ever tempted to remove it because
"release ran twice for one push", the answer is almost certainly a different fix
(concurrency groups — the workflow already uses `concurrency: { group: release,
cancel-in-progress: false }`), not weakening this guard.

---

## Rollback Procedure

**Published RubyGems versions cannot be silently replaced.** Once `convert_sdk
X.Y.Z` is pushed, re-pushing the same version is rejected. If a bad release slips
through:

1. Do **not** try to overwrite the version.
2. Push a conventional `fix:` commit that addresses the problem. The next release
   workflow publishes a new patch version (e.g. if `v1.2.3` was bad, the fix
   ships as `v1.2.4`).
3. If the bad version must be made un-installable, **yank** it:
   ```bash
   gem yank convert_sdk -v X.Y.Z
   ```
   `gem yank` removes the version from the index so it can no longer be resolved
   by `gem install` / `bundle install`, but it does **not** delete the artifact
   and the version number can never be reused. Prefer shipping a forward fix
   (`fix:`) over yanking unless the release is actively harmful.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `release.yml` didn't run after a merge to `main` | Quality Checks failed, or the triggering event wasn't a push, or the commits were all non-release types. | Check the Actions tab — the Release workflow only proceeds when Quality Checks concluded `success` AND the event was `push`. If Quality Checks failed, fix that. If the commits were `chore:`/`docs:`, no release is expected. |
| Release ran but published nothing | No release-worthy commit since the last tag (only `chore`/`docs`/`ci`/`test`/`style`/`perf`). | Expected — semantic-release succeeds silently with no version. Land a `feat:`/`fix:` to publish. |
| `gem push` failed / no RubyGems credential | The RubyGems Trusted Publisher is not registered (or the repo/workflow filename in the registration doesn't match `convertcom/ruby-sdk` ↔ `release.yml`). | Re-check the trusted-publisher entry on rubygems.org (One-Time Setup step 1). The workflow needs `id-token: write` (it has it) and the OIDC exchange step must run before semantic-release. |
| GitHub Release/tag created but gem missing | Should not happen — publish runs before the Release (publish-before-Release). If you see it, a manual tag was likely pushed out of band. | Do not hand-create `v*` tags. Let the pipeline own tagging. |
| `yarn release:dry-run` errors "This test run was not triggered in a known release branch" | Expected on any branch except `main`. | To force a full dry-run on a feature branch, temporarily add the branch to `release.config.mjs`'s `branches` array (discard before committing). On `main`, this means the local branch isn't pushed to `origin` — push first. |
| `Cannot find module '<preset>'` from a semantic-release plugin | The yarn node linker isn't producing a `node_modules/` tree the dynamic preset import can walk. | Confirm `.yarnrc.yml` selects the `node-modules` linker and re-run `yarn install --immutable`. |
| Forbidden release mechanism reintroduced (lint job fails) | A `@semantic-release/git`/`@semantic-release/changelog` plugin, a `rake release` task, `bundler/gem_tasks`, or `rubygems/release-gem` was added. | These are blocked by the release-safety step in the `Lint (RuboCop)` job. Remove the forbidden mechanism — publishing happens only via OIDC `release.yml`. |
