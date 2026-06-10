# frozen_string_literal: true

require "spec_helper"

# Story 4.7 — THE release gate. One deterministic end-to-end scenario proving
# every manager composes through the PUBLIC API only: factory wiring (closed in
# 4.6), config fetch, context decisioning, queue mechanics, payload building,
# header invariants on BOTH endpoints, and zero-secret-leakage redaction.
#
# Nothing here is hand-wired: the chain uses exactly the frozen public method
# names (+ConvertSdk.create+ -> +create_context+ -> +run_experience+ ->
# +run_feature+ -> +run_custom_segments+ -> +track_conversion+ -> +flush+) so a
# wiring regression between any two managers fails this spec and the release.
#
# Determinism is PINNED, never luck: visitor-1 + the fullstack-2 matching
# attributes bucket into experience 100218245 / variation 100299457 (the same
# vector proven by spec/integration/factory_wiring_spec.rb and the 2.9 bucket
# math). The golden wire payload is asserted field-by-field via a path-wise
# helper (no opaque deep-equality blob, no copy-paste) so a single drifted field
# names itself.

# Pinned deterministic vector (test-config.json, vendored 1.2). Module-namespaced
# constants (not in-block) so RuboCop's Lint/ConstantDefinitionInBlock is happy
# and the shared-example arguments can reference them at definition time.
module FullChainVector
  EXP_KEY = "test-experience-ab-fullstack-2"
  EXP_ID = "100218245"
  VAR_ID = "100299457"
  # feature-1 is carried by TWO active experiences; run_feature resolves across
  # ALL of them, so visitor-1 ALSO buckets into fullstack-3 (100218246 / 100299461).
  # Both sticky buckets are deterministic (MurmurHash3 + 2.9 bucket math), so the
  # conversion event's bucketingData attribution carries BOTH. Pinned, not luck.
  EXP2_ID = "100218246"
  VAR2_ID = "100299461"
  FEATURE_KEY = "feature-1"
  SEGMENT_KEY = "test-segments-1"
  SEGMENT_ID = "200299434"
  GOAL_KEY = "goal-without-rule"
  GOAL_ID = "100215962"
  ACCOUNT_ID = "10022898"
  PROJECT_ID = "10025986"
  VISITOR = "visitor-1"

  # Distinctive sentinel-looking secrets so the zero-leakage substring scan is
  # meaningful (NFR5). Long enough that the Redactor masks (first-4 + ellipsis)
  # rather than fully replacing.
  SDK_KEY = "test-sdk-key-XYZZY-acct-proj"
  SDK_SECRET = "test-secret-PLUGH-deadbeef"
end

RSpec.describe "Full chain release gate (Story 4.7)" do
  # Expose the pinned vector as instance methods so every example, helper, and
  # let-block resolves them by bare name (constant lookup inside RSpec blocks is
  # lexical and would NOT see the module constants). The module holds the single
  # source of the values; these one-line readers just surface them.
  FullChainVector.constants.each do |const|
    define_method(const.to_s.downcase) { FullChainVector.const_get(const) }
  end

  # The attributes that make visitor-1 eligible for fullstack-2 (transient
  # audience + staging environment; no location gate).
  let(:matching) do
    { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" }
  end

  let(:config_data) { ConfigFixture.config }

  # The track POST URL the factory resolves from the [project_id] template.
  let(:track_url) { "#{HttpStubs::TRACK_HOST}/#{project_id}/v1/track/%<key>s" }

  # Build a fetch-mode client (config arrives over HTTP — so the config endpoint
  # is exercised and its headers captured), timer-off (deterministic; explicit
  # flush only), pointed at the WebMock hosts. +secret+ toggles the Bearer matrix;
  # +sink+/+log_level+ drive the TRACE capture. Single construction helper — the
  # Bearer matrix and the TRACE capture all reuse it (no copy-paste).
  def build_client(key: sdk_key, secret: sdk_secret, sink: nil, log_level: nil)
    opts = {
      sdk_key: key,
      config_endpoint: HttpStubs::CONFIG_HOST,
      track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1",
      flush_interval: nil,
      data_refresh_interval: nil
    }
    opts[:sdk_key_secret] = secret unless secret.nil?
    opts[:sink] = sink unless sink.nil?
    opts[:log_level] = log_level unless log_level.nil?
    ConvertSdk.create(**opts)
  end

  # Stub the config fetch (vendored envelope) and the track POST for +key+,
  # both through the capture facility so headers + body are recorded.
  def stub_endpoints(key: sdk_key)
    stub_request(:get, "#{HttpStubs::CONFIG_HOST}/config/#{key}")
      .with(&capture).to_return(status: 200, body: JSON.generate(config_data), headers: json_headers)
    stub_request(:post, format(track_url, key: key))
      .with(&capture).to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)
  end

  # Drive the FULL ordered chain through the public API and return the client.
  # Every link is exercised; assertions live in the examples (this keeps the
  # ordered scenario in ONE place, reused by the payload + header + leakage gates
  # without duplication).
  def run_full_chain(client)
    context = client.create_context(visitor, matching)
    variation = context.run_experience(exp_key)
    feature = context.run_feature(feature_key)
    context.run_custom_segments([segment_key], { ruleData: { "enabled" => true } })
    context.track_conversion(goal_key, goal_data: { amount: 49.99, transaction_id: "tx-1" })
    # Duplicate same-goal conversion — deduped: NO second conversion event.
    context.track_conversion(goal_key, goal_data: { amount: 49.99, transaction_id: "tx-1" })
    # Force-bypass — a legitimate repeat transaction IS enqueued.
    context.track_conversion(goal_key, goal_data: { amount: 9.99, transaction_id: "tx-2" },
                                       force_multiple_transactions: true)
    client.flush("test")
    { context: context, variation: variation, feature: feature }
  end

  # The golden expected wire payload for the pinned chain. The visitor entry
  # carries NO +segments+ key: segments ride a visitor entry ONLY at the moment
  # the entry is first created (visitors_queue.rb#enqueue — JS parity
  # +if (segments) visitor.segments = …+), and the chain creates the entry on the
  # FIRST enqueue (the bucketing event from run_experience) BEFORE
  # run_custom_segments stores customSegments. This is the faithful wire shape,
  # asserted honestly rather than fabricated. (That run_custom_segments DID match
  # and store the segment id is proven separately via StoreData.)
  #
  # events order: bucketing (run_experience) → conversion (first track) →
  # conversion (force-bypass). The deduped duplicate adds NOTHING.
  def golden_payload
    expected_track_payload(
      account_id: account_id,
      project_id: project_id,
      visitors: [
        {
          "visitorId" => visitor,
          "events" => [
            bucketing_event(experience_id: exp_id, variation_id: var_id),
            full_chain_conversion(amount: 49.99, transaction_id: "tx-1"),
            full_chain_conversion(amount: 9.99, transaction_id: "tx-2")
          ]
        }
      ]
    )
  end

  # The pinned conversion event for THIS chain — composed from the shared 4.3
  # golden builder (spec/support/http_stubs.rb#conversion_event), differing only
  # by the revenue/transaction data. visitor-1 IS bucketed, so bucketingData is
  # always present. No copy-paste of the event shape — the shape lives in the
  # shared builder; this just supplies the per-call data.
  def full_chain_conversion(amount:, transaction_id:)
    conversion_event(
      goal_id: goal_id,
      goal_data: { "amount" => amount, "transactionId" => transaction_id },
      # visitor-1 is bucketed into BOTH feature-1-carrying experiences by the
      # run_experience + run_feature chain, so the attribution carries both.
      bucketing_data: { exp_id => var_id, exp2_id => var2_id }
    )
  end

  # Field-by-field assertion: walk the expected structure path-wise and assert
  # each leaf against the actual, so a drifted field names its own path in the
  # failure (no opaque deep-equality blob). Recurses Hashes and Arrays; asserts
  # key-set equality at each Hash node so an EXTRA actual key (e.g. a leaked
  # +segments+) also fails.
  def assert_wire_equal(expected, actual, path = "$")
    case expected
    when Hash then assert_wire_hash(expected, actual, path)
    when Array then assert_wire_array(expected, actual, path)
    else expect(actual).to eq(expected), "#{path}: expected #{expected.inspect}, got #{actual.inspect}"
    end
  end

  # Assert a Hash node: same key SET (catches a leaked extra key) then recurse.
  def assert_wire_hash(expected, actual, path)
    expect(actual).to be_a(Hash), "#{path}: expected Hash, got #{actual.class}"
    expect(actual.keys).to match_array(expected.keys),
                           "#{path}: key set drift — expected #{expected.keys.sort}, got #{actual.keys.sort}"
    expected.each { |k, v| assert_wire_equal(v, actual[k], "#{path}.#{k}") }
  end

  # Assert an Array node: same length then recurse element-wise.
  def assert_wire_array(expected, actual, path)
    expect(actual).to be_a(Array), "#{path}: expected Array, got #{actual.class}"
    expect(actual.size).to eq(expected.size), "#{path}: length drift"
    expected.each_with_index { |v, i| assert_wire_equal(v, actual[i], "#{path}[#{i}]") }
  end

  def parsed_track_body
    body = captured_request_for(:post).body
    body.is_a?(String) ? JSON.parse(body) : body
  end

  # The single captured request matching +http_method+ (fails on zero or many).
  def captured_request_for(http_method)
    matches = captured_requests.select { |r| r.http_method == http_method }
    expect(matches.size).to eq(1), "expected exactly one #{http_method.upcase} request, got #{matches.size}"
    matches.first
  end

  # Case-insensitive header lookup over a captured request's header hash.
  def header(request, name)
    pair = request.headers.find { |k, _| k.casecmp?(name) }
    pair&.last
  end

  describe "AC#1 — ordered chain + field-by-field payload" do
    before { stub_endpoints }

    it "buckets visitor-1 into the pinned frozen variation (NOT a sentinel)" do
      result = run_full_chain(build_client)
      variation = result[:variation]

      expect(variation).to be_a(ConvertSdk::BucketedVariation)
      expect(variation).to be_frozen
      expect(variation.experience_id).to eq(exp_id)
      expect(variation.id).to eq(var_id)
    end

    it "resolves feature-1 across both carrying experiences with typed variables" do
      # feature-1 is carried by two active experiences; run_feature returns the
      # Array of enabled BucketedFeatures (JS runFeature parity), each with its
      # variables cast to the declared types (boolean "false"/"true" -> false/true;
      # string passthrough). Index by experience so the assertion is order-stable.
      features = Array(run_full_chain(build_client)[:feature])
      by_exp = features.to_h { |bf| [bf.experience_id, bf] }

      expect(features.size).to eq(2)
      features.each { |bf| expect(bf.status).to eq(ConvertSdk::FeatureStatus::ENABLED) }

      expect(by_exp[exp_id].variables["enabled"]).to be(false)
      expect(by_exp[exp_id].variables["caption"]).to eq("Not allowed")
      expect(by_exp[exp2_id].variables["enabled"]).to be(true)
      expect(by_exp[exp2_id].variables["caption"]).to eq("Allowed")
    end

    it "matches and stores the custom segment id (segments link exercised)" do
      result = run_full_chain(build_client)
      stored = result[:context].get_visitor_data["segments"]

      expect(stored["customSegments"]).to include(segment_id)
    end

    it "POSTs the golden wire payload field-by-field (dedup + force-bypass proven)" do
      run_full_chain(build_client)

      assert_wire_equal(golden_payload, parsed_track_body)
    end

    it "carries exactly three events: bucketing + first conversion + forced conversion" do
      run_full_chain(build_client)
      events = parsed_track_body.dig("visitors", 0, "events")

      # Two track calls on the same goal collapse to ONE conversion event (dedup);
      # the force-bypass adds the third. Four track_conversion-eligible calls,
      # three events.
      expect(events.map { |e| e["eventType"] }).to eq(%w[bucketing conversion conversion])
    end
  end

  describe "AC#2 — header invariants on BOTH endpoints" do
    it "sends User-Agent: ConvertAgent/1.0 on every request (config + track)" do
      stub_endpoints
      run_full_chain(build_client)

      %i[get post].each do |verb|
        expect(header(captured_request_for(verb), "User-Agent")).to eq("ConvertAgent/1.0")
      end
    end

    # The Bearer matrix as a shared example so with/without-secret reuse one body.
    shared_examples "a bearer matrix run" do |secret, expected_bearer|
      let(:run_key) { secret ? sdk_key : "#{sdk_key}-nosecret" }

      it "applies Authorization=#{expected_bearer.inspect} on config AND track" do
        stub_endpoints(key: run_key)
        run_full_chain(build_client(key: run_key, secret: secret))

        %i[get post].each do |verb|
          expect(header(captured_request_for(verb), "Authorization")).to eq(expected_bearer)
        end
      end
    end

    context "with a configured secret" do
      include_examples "a bearer matrix run", FullChainVector::SDK_SECRET, "Bearer #{FullChainVector::SDK_SECRET}"
    end

    context "without a secret" do
      include_examples "a bearer matrix run", nil, nil
    end
  end

  describe "AC#3 — zero secret leakage across the full TRACE lifecycle (NFR5)" do
    it "emits the masked secret forms but NEVER the raw sdk_key / sdk_key_secret" do
      sink = CapturingSink.new
      stub_endpoints
      # TRACE + sink injected at create so init-time lines (the HttpClient config
      # GET, whose URL carries the raw sdk_key) are captured and proven redacted.
      run_full_chain(build_client(sink: sink, log_level: ConvertSdk::LogLevel::TRACE))

      log = sink.joined
      # The init-time config GET line MUST have been captured (proves we observe
      # the full lifecycle, not just post-create).
      expect(log).to include("HttpClient#request: GET")

      # Zero raw secrets anywhere across init -> decision -> track -> flush.
      expect(log).not_to include(sdk_key)
      expect(log).not_to include(sdk_secret)

      # The masked form of the sdk_key (first-4 + ellipsis) MUST appear — proving
      # the Redactor actually ran on a line that carried the secret (the config
      # URL), not that the secret simply never appeared.
      masked_key = "#{sdk_key[0, 4]}…"
      expect(log).to include(masked_key)
    end
  end
end
