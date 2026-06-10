# Vendored Fixture Provenance

These fixtures are copied **verbatim** from upstream Convert SDK repositories and
**must never be hand-edited**. They are the cross-SDK parity goldens — editing them
would silently break the byte-identical-hashing guarantee they exist to enforce.

To refresh a fixture, re-copy it from its source path below and update the commit
SHA and copy date in this file. Never patch the JSON in place.

| Vendored file | Source repo | Source path | Source commit SHA | Copy date | SHA-256 |
|---|---|---|---|---|---|
| `spec/fixtures/cross_sdk/test-vectors.json` | `php-sdk` | `tests/CrossSdk/test-vectors.json` | `22f41b80c06c59ef49f14a2a38d6e5f5f7d7b940` | 2026-06-07 | `8f13a0dffe4b02dfbde6f4cf55e535cb851edcbf4e6e5d5e8fd8aa1f96c69d81` |
| `spec/fixtures/cross_sdk/rule-test-vectors.json` | `php-sdk` | `tests/CrossSdk/rule-test-vectors.json` | `22f41b80c06c59ef49f14a2a38d6e5f5f7d7b940` | 2026-06-07 | `e0027193269e24f9fe50969b5a9446a42bae330def5b1eab0d359c7f663fc686` |
| `spec/fixtures/test-config.json` | `javascript-sdk` | `packages/js-sdk/tests/test-config.json` | `e7b2da303d053b01c81aac3e94da90d0cb3eee14` | 2026-06-07 | `01c1c2fb973342e6bd4b5aacc544b5a14cfe06de2e83f582ef90c49dbde8ed88` |

## Consumption

- `test-vectors.json` (75 hash vectors) — consumed now by the Story 1.2 parity suite (`spec/cross_sdk/hash_vectors_spec.rb`).
- `rule-test-vectors.json` — vendored now, consumed by the rule engine in Story 2.10.
- `test-config.json` — vendored now, consumed from Story 2.5 onward; canonical behavioral fixture for the full-chain spec (Story 4.7).
