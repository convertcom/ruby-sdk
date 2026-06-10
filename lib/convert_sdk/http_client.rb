# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "openssl"

module ConvertSdk
  # The single hardened HTTP port every SDK request flows through.
  #
  # +HttpClient+ is the *only* file in the gem that touches +Net::HTTP+ (a cheap
  # architectural regression test asserts this). Every request it sends carries
  # the ConvertAgent wire invariant and bounded timeouts, and every failure it
  # encounters is converted into a failed {Response} rather than raised — the
  # port NEVER raises to callers, so the config fetch (Story 2.5) and event
  # delivery (Story 4.1) consumers degrade gracefully on a failed response.
  #
  # == The ConvertAgent wire invariant
  #
  # The metrics endpoint's bot filter silently DROPS server-side events whose
  # +User-Agent+ is not +ConvertAgent/1.0+. The header is therefore applied
  # LAST, after every header merge, so it cannot be overridden by an
  # integrator-supplied +User-Agent+. Without it, tracking events would vanish
  # silently in production. (JS/PHP precedent: set unconditionally after merge.)
  #
  # == Bounded timeouts
  #
  # Both +open_timeout+ and +read_timeout+ are set explicitly on EVERY request
  # (a deliberate improvement over the JS SDK, which sets none). The SDK can
  # never hang a host thread waiting on a slow or dead endpoint.
  #
  # == TLS / Bearer / proxies
  #
  # HTTPS endpoints use TLS with verification ON (+verify_mode+ is never
  # +VERIFY_NONE+). An +Authorization: Bearer ...+ header is stripped (and a
  # warning logged) on any non-HTTPS endpoint so the SDK key secret never
  # crosses the wire in plaintext. Proxies are honoured through the standard
  # +Net::HTTP+ environment conventions (+http_proxy+/+https_proxy+/+no_proxy+).
  #
  # == JSON boundary
  #
  # Callers pass and receive Ruby hashes; JSON encode/decode happens only here.
  # A request +body+ hash is rendered with +JSON.generate+; a response body is
  # parsed with +JSON.parse+ (string keys). A parse failure is logged and yields
  # +body: nil+ on an otherwise intact response.
  #
  # All logging goes through the injected {LogManager} (never +puts+), so the
  # {Redactor} masks secrets and strips URL query strings from every line.
  class HttpClient
    # The mandatory wire User-Agent. Applied LAST so it is unoverridable.
    USER_AGENT = "ConvertAgent/1.0"

    # The status used for a failed Response when no HTTP response was received
    # (network error / timeout). Callers MUST use {Response#success?}, never
    # compare the status integer, for error detection.
    FAILURE_STATUS = 0

    # An immutable result of a single HTTP request.
    #
    # +status+ is the HTTP status integer (or {FAILURE_STATUS} on a transport
    # failure); +body+ is the parsed JSON object (or nil); +headers+ is the
    # response header hash; +#success?+ is a strict 2xx predicate.
    #
    # Declared as an explicit +class < Struct.new(...)+ subclass (NOT the
    # +Struct.new do...end+ block form): this is the only shape Steep can
    # statically resolve +#success?+ and the keyword constructor against, the
    # same reason the frozen value objects (BucketedVariation/BucketedFeature)
    # use it.
    class Response < Struct.new(:status, :body, :headers, keyword_init: true)
      # @return [void] builds the struct then freezes it (immutable value object).
      def initialize(**)
        super
        freeze
      end

      # @return [Boolean] true iff +status+ is in the 2xx range.
      def success?
        status.between?(200, 299)
      end
    end

    # @param log_manager [LogManager] the injected logging surface. All output
    #   flows through it so the {Redactor} applies.
    # @param open_timeout [Numeric] connection-establishment timeout (seconds).
    # @param read_timeout [Numeric] response-read timeout (seconds).
    def initialize(log_manager:, open_timeout:, read_timeout:)
      @log_manager = log_manager
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Send one HTTP request and return a frozen {Response}. Never raises: any
    # transport failure is logged and returned as a failed response.
    #
    # @param method [Symbol] +:get+ / +:post+ / etc.
    # @param url [String] the absolute request URL.
    # @param headers [Hash{String=>String}] caller headers (merged before the
    #   wire invariant is applied last).
    # @param body [Hash, nil] a request body; JSON-encoded if present.
    # @return [Response] frozen; +success?+ is the only valid error check.
    def request(method:, url:, headers: {}, body: nil)
      uri = URI.parse(url)
      https = uri.scheme == "https"
      wire_headers = build_headers(headers, https)
      @log_manager.debug("HttpClient#request: #{method.to_s.upcase} #{url}")

      perform(method, uri, https, wire_headers, body)
    rescue StandardError => e
      @log_manager.error("HttpClient#request: request failed (#{e.class}: #{e.message})")
      failed_response
    end

    private

    # Open a per-call connection (no reuse — the seam admits net-http-persistent
    # post-MVP), set explicit timeouts, send the request, and map the result to
    # a frozen {Response}.
    def perform(method, uri, https, wire_headers, body)
      host = uri.host or raise(ArgumentError, "URL has no host: #{uri}")
      Net::HTTP.start(
        host, uri.port,
        use_ssl: https,
        open_timeout: @open_timeout,
        read_timeout: @read_timeout
      ) do |http|
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        net_response = http.request(build_request(method, uri, wire_headers, body))
        build_response(net_response)
      end
    end

    # Build the wire headers: caller headers first, then the ConvertAgent UA
    # applied LAST (unoverridable), then the Bearer guard for non-HTTPS.
    def build_headers(headers, https)
      merged = {} #: Hash[String, String]
      headers.each { |key, value| merged[key.to_s] = value }
      merged["User-Agent"] = USER_AGENT
      guard_bearer(merged, https)
      merged
    end

    # Strip an Authorization header on a non-HTTPS endpoint (and warn): the SDK
    # key secret must never cross the wire in plaintext.
    def guard_bearer(headers, https)
      return if https
      return unless headers.key?("Authorization")

      headers.delete("Authorization")
      @log_manager.warn("HttpClient#request: stripped Authorization on non-HTTPS endpoint")
    end

    # Construct the Net::HTTP request object for +method+, attaching the JSON
    # body (if any) and all wire headers.
    def build_request(method, uri, wire_headers, body)
      request_class = Net::HTTP.const_get(method.to_s.capitalize)
      net_request = request_class.new(uri)
      wire_headers.each { |key, value| net_request[key] = value }
      if body
        net_request["Content-Type"] ||= "application/json"
        net_request.body = JSON.generate(body)
      end
      net_request
    end

    # Map a Net::HTTPResponse to a frozen {Response}, parsing the JSON body.
    def build_response(net_response)
      Response.new(
        status: net_response.code.to_i,
        body: parse_body(net_response.body),
        headers: flatten_headers(net_response)
      )
    end

    # Parse a response body as JSON (string keys). A blank body or a parse
    # failure yields nil; a failure is logged.
    def parse_body(raw)
      return nil if raw.nil? || raw.empty?

      JSON.parse(raw)
    rescue JSON::ParserError => e
      @log_manager.warn("HttpClient#request: response body is not JSON (#{e.class})")
      nil
    end

    # Flatten Net::HTTP's multi-value header representation into a simple Hash.
    def flatten_headers(net_response)
      headers = {} #: Hash[String, String]
      net_response.each_header { |key, value| headers[key] = value }
      headers
    end

    # A failed Response with no HTTP status. Frozen, like every Response.
    def failed_response
      Response.new(status: FAILURE_STATUS, body: nil, headers: {}) #: Response
    end
  end
end
