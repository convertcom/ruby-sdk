# frozen_string_literal: true

require "json"

# Shared WebMock helpers for HttpClient and its downstream consumers.
#
# The hardened HTTP port (Story 1.5) is the single seam every SDK request flows
# through; the two real consumers are the config fetch (+GET
# {config_endpoint}/config/{sdkKey}+, Story 2.5) and event delivery (+POST
# {track_endpoint}/track/{sdkKey}+, Story 4.1). This module centralises the
# canned stubs for both endpoints plus a request-capture facility so specs can
# assert on BOTH the request payload and the request headers — which Story 4.7's
# full-chain gate needs on both endpoints simultaneously.
#
# Mixed into the RSpec config (see spec_helper). Every stubbed request is also
# recorded into {#captured_requests} so a spec can inspect the exact method,
# URI, headers, and body that reached the wire after HttpClient applied the
# ConvertAgent wire invariant and the JSON boundary.
module HttpStubs
  # Default endpoints — opaque test hosts, never contacted (WebMock lockdown).
  CONFIG_HOST = "https://cdn-settings.example.test"
  TRACK_HOST = "https://track.example.test"

  # A captured wire request: the immutable facts a spec asserts against.
  # +http_method+ (not +method+) avoids overriding +Object#method+.
  CapturedRequest = Struct.new(:http_method, :uri, :headers, :body, keyword_init: true)

  # Every request observed through {#capture_with}. A fresh array per example
  # (RSpec re-includes the module and runs +before+ resets via {#reset_http_capture}).
  def captured_requests
    @captured_requests ||= []
  end

  # Reset capture state between examples. Called from a global +before+ hook.
  def reset_http_capture
    @captured_requests = []
  end

  # A WebMock +with+ block that records the request, then always matches.
  # Usage: +stub_request(:get, url).with(&capture).to_return(...)+.
  #
  # @return [Proc] a block suitable for WebMock's +with+ that records and matches.
  def capture
    proc do |request|
      captured_requests << CapturedRequest.new(
        http_method: request.method,
        uri: request.uri.to_s,
        headers: request.headers || {},
        body: request.body
      )
      true
    end
  end

  # Stub +GET {CONFIG_HOST}/config/{sdk_key}+ returning a canned config body.
  #
  # @param sdk_key [String] the SDK key path segment.
  # @param status [Integer] HTTP status to return (default 200).
  # @param body [Hash] JSON body to return (default a minimal config shape).
  # @return [WebMock::RequestStub]
  def stub_config(sdk_key: "sdk-key-1", status: 200, body: canned_config)
    stub_request(:get, "#{CONFIG_HOST}/config/#{sdk_key}")
      .with(&capture)
      .to_return(status: status, body: JSON.generate(body), headers: json_headers)
  end

  # Stub +POST {TRACK_HOST}/track/{sdk_key}+ returning a canned ack body.
  #
  # @param sdk_key [String] the SDK key path segment.
  # @param status [Integer] HTTP status to return (default 200).
  # @param body [Hash] JSON body to return (default a minimal ack shape).
  # @return [WebMock::RequestStub]
  def stub_track(sdk_key: "sdk-key-1", status: 200, body: canned_ack)
    stub_request(:post, "#{TRACK_HOST}/track/#{sdk_key}")
      .with(&capture)
      .to_return(status: status, body: JSON.generate(body), headers: json_headers)
  end

  # The single captured request (fails the spec if zero or more than one).
  #
  # @return [CapturedRequest]
  def captured_request
    expect(captured_requests.size).to eq(1)
    captured_requests.first
  end

  # A canned minimal config payload (string keys, as on the wire).
  def canned_config
    { "experiences" => {}, "audiences" => {}, "_meta" => { "ok" => true } }
  end

  # The vendored realistic config envelope (Story 1.2's +test-config.json+),
  # parsed to a string-keyed Hash. This is the actual wire shape the Client
  # installs and the DataManager readers are derived from — use it whenever a
  # spec needs a config fetch to return a representative project config.
  #
  # @return [Hash{String=>Object}] the parsed +test-config.json+ envelope.
  def vendored_config
    JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__)))
  end

  # Stub +GET {CONFIG_HOST}/config/{sdk_key}+ serving the vendored realistic
  # config envelope (Story 2.5 Client fetch path). The +environment+ query
  # parameter, when the Client appends one, still matches (WebMock matches the
  # path; the capture block records the full URI for assertions).
  #
  # @param sdk_key [String] the SDK key path segment.
  # @param status [Integer] HTTP status to return (default 200).
  # @return [WebMock::RequestStub]
  def stub_vendored_config(sdk_key: "sdk-key-1", status: 200)
    stub_request(:get, %r{\A#{Regexp.escape(CONFIG_HOST)}/config/#{Regexp.escape(sdk_key)}(\?.*)?\z})
      .with(&capture)
      .to_return(status: status, body: JSON.generate(vendored_config), headers: json_headers)
  end

  # A canned minimal track-ack payload.
  def canned_ack
    { "status" => "queued", "received" => 1 }
  end

  # Standard JSON response headers.
  def json_headers
    { "Content-Type" => "application/json" }
  end
end
