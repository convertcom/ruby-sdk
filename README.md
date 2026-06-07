# Convert Ruby SDK

The official Convert Experiences FullStack Ruby SDK — server-side A/B testing,
feature flags, and personalizations for Ruby applications. Bucketing-compatible
with the Convert JavaScript SDK. Zero runtime dependencies.

> This is a scaffold stub. Full usage documentation lands in a later story.

## Requirements

- Ruby >= 3.1 (CRuby 3.1–3.4 and JRuby are supported)

## Development

```sh
bundle install        # install dev/test dependencies
bundle exec rake      # run the default task: RSpec + RuboCop
bundle exec rbs -I sig validate   # validate RBS signatures
bundle exec steep check           # static type check
```

Publishing is handled exclusively by the OIDC release workflow — there is no
`rake release` task.

## License

Apache-2.0. See [LICENSE](LICENSE).
