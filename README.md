# ConvertSdk

Convert Experiences FullStack SDK for Ruby — a zero-dependency Ruby SDK for
feature flags, A/B testing, and server-side experimentation on the
[Convert Experiences](https://www.convert.com) platform.

> This is a scaffold stub. The full README (installation, usage, examples)
> lands in Story 5.3.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then:

- `bundle exec rake` — run the default task (specs + RuboCop).
- `bundle exec rspec` — run the test suite with coverage.
- `bundle exec rubocop` — lint.
- `bundle exec rbs validate && bundle exec steep check` — type-check.
- `bin/console` — interactive prompt to experiment with the library.

Releases are published exclusively through the trusted-publishing
GitHub Actions workflow (`release.yml`, added in Epic 5). There is no
`rake release` task, and gems are never pushed from a developer machine.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
