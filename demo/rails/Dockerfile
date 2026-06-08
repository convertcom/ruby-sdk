# The demo image. Teaching material: the smallest image that runs a Rails app
# under a real Puma cluster against the SDK built from the working tree.
#
# Build context note: docker-compose.yml sets the build context to the REPO ROOT
# (two levels up) so the `gem "convert_sdk", path: "../.."` dependency can be
# resolved INSIDE the image — the gem source must be present in the build context.
ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim

# Minimal build deps: a C toolchain for native gems Rails pulls in (e.g. nokogiri
# may need it depending on the resolved set). No database client libs — the demo
# has no DB.
RUN apt-get update -qq \
  && apt-get install --no-install-recommends -y build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the WHOLE repo (build context = repo root) so the path gem resolves. The
# demo's Gemfile lives at demo/rails/Gemfile and points at ../.. (the repo root)
# for convert_sdk.
COPY . /app

WORKDIR /app/demo/rails

# No committed Gemfile.lock (see .gitignore) — bundle resolves per build, the
# same per-job resolution the CI matrix relies on.
RUN gem install bundler && bundle install

EXPOSE 3000

# Boot the Puma CLUSTER (workers 2 + preload_app! live in config/puma.rb). This
# is the production deployment shape the fork-safety proof depends on.
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
