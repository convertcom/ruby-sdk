/*
 * release.config.mjs — semantic-release configuration for the Convert Ruby SDK.
 *
 * Triggered by `.github/workflows/release.yml` on every successful "Quality
 * Checks" run on `main` (via `workflow_run`). Analyzes the conventional
 * commits since the last tag, decides the next version, writes that version
 * into `lib/convert_sdk/version.rb` (build-time, NOT committed), builds and
 * pushes the gem to RubyGems.org via OIDC Trusted Publishing, then creates the
 * `vX.Y.Z` tag + a GitHub Release carrying the generated notes.
 *
 * IMPORTANT: this release NEVER pushes a commit to `main`. semantic-release
 * core pushes only the *tag* (a `refs/tags/*` ref — not gated by the branch
 * ruleset) and `@semantic-release/github` creates the Release via the API. The
 * version write in `version.rb` is a build-time, working-tree write consumed by
 * `gem build` and intentionally NOT committed; the NEXT release derives its
 * version from this run's git tag (FR66).
 *
 * Plugin order is LOAD-BEARING — deviation is an architecture violation
 * (Story 5.4 AC-1):
 *
 *   1. commit-analyzer          → decide next version from feat/fix/BREAKING
 *   2. release-notes-generator  → render markdown release notes
 *   3. exec (prepareCmd)        → write nextRelease.version into version.rb
 *   4. exec (publishCmd)        → gem build + gem push to RubyGems.org
 *   5. github                   → create vX.Y.Z tag + GitHub Release (via API)
 *
 * Publish-before-Release: if step 4 (gem push) fails, semantic-release aborts
 * BEFORE step 5 — so no GitHub Release/tag is finalized without a corresponding
 * gem on RubyGems.org (AC-3). The repo stays in its pre-release state; the next
 * push retries.
 *
 * Adapted from the Convert PHP SDK's release.config.mjs (types map + GitHub
 * settings) and the Android SDK's release.config.mjs (the @semantic-release/exec
 * twin-step pattern). DELIBERATE Ruby divergences:
 *   - uses the STANDARD @semantic-release/commit-analyzer (PHP uses a custom
 *     rollover-version-plugin.mjs in its place — not adopted here);
 *   - adds @semantic-release/exec (PHP has no exec plugins; Android precedent).
 *
 * FORBIDDEN here (ratified house lessons — Android qs-03/qs-04): no
 * @semantic-release/git (nothing commits to main), no @semantic-release/changelog
 * (no committed CHANGELOG — the gemspec's changelog_uri points at GitHub
 * Releases).
 */

export default {
  // Only publish from `main`. `yarn release:dry-run` previews on any branch,
  // but `yarn release` refuses to publish from anything else.
  branches: ['main'],

  // All git tags use the `v` prefix (v1.0.0, v1.2.3). Matches the PHP/Android
  // SDKs.
  tagFormat: 'v${version}',

  plugins: [
    // 1. Map conventional commits to SemVer impact.
    //    feat: X            → minor bump
    //    fix: X             → patch bump
    //    BREAKING CHANGE: … → major bump
    //    Anything else (chore/docs/ci/test/style/perf/refactor) → no release.
    [
      '@semantic-release/commit-analyzer',
      {
        preset: 'conventionalcommits',
      },
    ],

    // 2. Build the markdown release notes. Mirrors the PHP/Android types map —
    //    only feat/fix/refactor are surfaced to users; maintenance commit types
    //    (chore/docs/ci/test/style/perf) are hidden.
    [
      '@semantic-release/release-notes-generator',
      {
        preset: 'conventionalcommits',
        presetConfig: {
          types: [
            { type: 'feat', section: 'Features' },
            { type: 'fix', section: 'Bug Fixes' },
            { type: 'refactor', section: 'Refactoring' },
            { type: 'chore', hidden: true },
            { type: 'docs', hidden: true },
            { type: 'ci', hidden: true },
            { type: 'test', hidden: true },
            { type: 'style', hidden: true },
            { type: 'perf', hidden: true },
          ],
        },
      },
    ],

    // 3. Write `nextRelease.version` into lib/convert_sdk/version.rb so the gem
    //    builds carrying the new version. This is an UNCOMMITTED working-tree
    //    write — `main` never receives a version-bump commit; the next release
    //    derives its version from this run's git tag (FR66). The Ruby
    //    single-quoted heredoc-free sed keeps it dependency-free (stdlib only).
    [
      '@semantic-release/exec',
      {
        prepareCmd:
          'ruby -e \'f="lib/convert_sdk/version.rb"; s=File.read(f); s.sub!(/VERSION = "[^"]*"/, %Q{VERSION = "${nextRelease.version}"}); File.write(f, s)\'',
      },
    ],

    // 4. Build + push the gem to RubyGems.org. Runs AFTER the version write so
    //    the built gem carries the new version, and BEFORE the GitHub Release so
    //    a failed `gem push` aborts the chain (no Release without a published
    //    gem — AC-3). Authentication is via OIDC Trusted Publishing: the
    //    `rubygems/configure-rubygems-credentials` step in release.yml writes a
    //    short-lived credential before semantic-release runs — NO API-key secret
    //    exists anywhere (FR67 / NFR8).
    [
      '@semantic-release/exec',
      {
        publishCmd: 'gem build convert_sdk.gemspec && gem push convert_sdk-*.gem',
      },
    ],

    // 5. Create the `vX.Y.Z` tag + a GitHub Release with the generated notes.
    //    semantic-release core pushes the tag (a `refs/tags/*` ref — NOT gated
    //    by the `main` branch ruleset); this plugin creates the Release via the
    //    GitHub API. There is NO commit-back to `main`.
    [
      '@semantic-release/github',
      {
        // release.yml grants `contents: write` only (besides id-token for OIDC);
        // the plugin's default PR/issue success comments AND `releasedLabels`
        // write to issues/PRs (need issues:write + pull-requests:write) and
        // would 403. Disable them all — the Release + tag (contents:write) are
        // all we need. (Android qs-03 / TD-2.)
        successComment: false,
        failComment: false,
        failTitle: false,
        releasedLabels: false,
      },
    ],
  ],
};
