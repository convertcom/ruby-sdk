# frozen_string_literal: true

Rails.application.routes.draw do
  # Health + worker-identity endpoint. Returns this Ruby process's PID — the
  # fork smoke uses it to discover which worker served a request, then embeds
  # that PID in the visitor id (smoke-test-{pid}-{n}) so the stub can prove BOTH
  # forked workers delivered events. See script/fork_smoke.rb.
  get "/pid", to: "demo#pid"

  # The full-loop demo: run an experience, evaluate a feature, custom segments,
  # track a revenue conversion, and flush. Accepts a `visitor_id` param (the demo
  # identity). Returns a JSON summary of what the SDK decided.
  get "/demo", to: "demo#run"

  # Explicit flush surface (the recipe also flushes via the background timer; this
  # endpoint lets a human/CI force a synchronous flush and observe delivery).
  post "/flush", to: "demo#flush"

  root to: "demo#run"
end
