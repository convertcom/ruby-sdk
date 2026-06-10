# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::HttpClient do
  let(:sink) { CapturingSink.new }
  let(:log_manager) do
    ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
  end

  # An HttpClient with deterministic explicit timeouts and a capturing logger.
  def client(open_timeout: 1.5, read_timeout: 3.0)
    described_class.new(
      log_manager: log_manager,
      open_timeout: open_timeout,
      read_timeout: read_timeout
    )
  end

  describe "Response value object" do
    it "is a frozen Struct exposing status/body/headers and #success?" do
      stub_config
      response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(response).to be_frozen
      expect(response.status).to eq(200)
      expect(response.headers).to be_a(Hash)
      expect(response.success?).to be(true)
    end

    # #success? is a strict 2xx predicate, independent of the body.
    {
      200 => true, 201 => true, 204 => true,
      301 => false, 400 => false, 404 => false, 500 => false, 503 => false
    }.each do |status, expected|
      it "##success? is #{expected} for HTTP #{status}" do
        stub_config(status: status)
        response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
        expect(response.success?).to be(expected)
      end
    end
  end

  describe "JSON boundary" do
    it "decodes a JSON response body into a string-keyed Hash" do
      stub_config(body: { "experiences" => { "e1" => 1 } })
      response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(response.body).to eq("experiences" => { "e1" => 1 })
    end

    it "encodes a request Hash body to JSON on the wire (POST round-trip)" do
      stub_track
      client.request(
        method: :post,
        url: "#{HttpStubs::TRACK_HOST}/track/sdk-key-1",
        body: { "event" => "view", "n" => 2 }
      )
      expect(JSON.parse(captured_request.body)).to eq("event" => "view", "n" => 2)
    end

    it "logs and returns body: nil when the response is not valid JSON" do
      stub_request(:get, "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
        .to_return(status: 200, body: "<<not json>>", headers: { "Content-Type" => "application/json" })
      response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(response.success?).to be(true)
      expect(response.body).to be_nil
      expect(sink.joined).to include("HttpClient#request")
    end
  end

  describe "explicit timeouts (never hang a host thread)" do
    it "converts a connection timeout into a failed Response without raising" do
      stub_request(:get, "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1").to_timeout
      response = nil
      expect do
        response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      end.not_to raise_error
      expect(response.success?).to be(false)
      expect(response.status).to eq(0)
      expect(sink.joined).to include("HttpClient#request")
    end

    it "sets explicit open_timeout and read_timeout on the Net::HTTP object" do
      captured_http = nil
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
        original.call(*args, **kwargs) do |http|
          captured_http = http
          block.call(http)
        end
      end
      stub_config
      client(open_timeout: 2.0, read_timeout: 4.0)
        .request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(captured_http.open_timeout).to eq(2.0)
      expect(captured_http.read_timeout).to eq(4.0)
    end
  end

  describe "ConvertAgent wire invariant (AC#3)" do
    it "sends User-Agent: ConvertAgent/1.0 by default" do
      stub_config
      client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(captured_request.headers["User-Agent"]).to eq(ConvertSdk::HttpClient::USER_AGENT)
    end

    it "overrides an integrator-supplied User-Agent (invariant cannot be overridden)" do
      stub_config
      client.request(
        method: :get,
        url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1",
        headers: { "User-Agent" => "Custom/9.9" }
      )
      expect(captured_request.headers["User-Agent"]).to eq("ConvertAgent/1.0")
    end
  end

  describe "TLS / Bearer / proxy hardening (AC#4)" do
    let(:bearer) { { "Authorization" => "Bearer sdk-key-secret-xyz" } }

    it "attaches Authorization on an HTTPS endpoint" do
      stub_config
      client.request(
        method: :get,
        url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1",
        headers: bearer
      )
      expect(captured_request.headers["Authorization"]).to eq("Bearer sdk-key-secret-xyz")
    end

    it "strips Authorization on a plaintext http:// endpoint and warn-logs" do
      stub_request(:get, "http://insecure.example.test/config/sdk-key-1")
        .with(&capture)
        .to_return(status: 200, body: JSON.generate({}), headers: { "Content-Type" => "application/json" })
      client.request(
        method: :get,
        url: "http://insecure.example.test/config/sdk-key-1",
        headers: bearer
      )
      expect(captured_request.headers).not_to have_key("Authorization")
      expect(sink.entries.map(&:first)).to include(:warn)
    end

    it "uses TLS (use_ssl true) for https endpoints" do
      use_ssl_seen = nil
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
        use_ssl_seen = kwargs[:use_ssl]
        original.call(*args, **kwargs, &block)
      end
      stub_config
      client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(use_ssl_seen).to be(true)
    end

    it "never disables TLS verification (no VERIFY_NONE)" do
      verify_mode_seen = :unset
      allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
        original.call(*args, **kwargs) do |http|
          verify_mode_seen = http.verify_mode
          block.call(http)
        end
      end
      stub_config
      client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      expect(verify_mode_seen).not_to eq(OpenSSL::SSL::VERIFY_NONE)
    end
  end

  describe "never-raise semantics (AC#2)" do
    it "converts a SocketError into a failed Response without raising" do
      stub_request(:get, "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1").to_raise(SocketError.new("getaddrinfo"))
      response = nil
      expect do
        response = client.request(method: :get, url: "#{HttpStubs::CONFIG_HOST}/config/sdk-key-1")
      end.not_to raise_error
      expect(response.success?).to be(false)
      expect(response.status).to eq(0)
      expect(response.body).to be_nil
    end
  end

  describe "single Net::HTTP site (architectural regression)" do
    it "is the only file under lib/ that references Net::HTTP" do
      lib_root = File.expand_path("../../lib", __dir__)
      offenders = Dir[File.join(lib_root, "**", "*.rb")].select do |path|
        File.read(path).include?("Net::HTTP")
      end
      expect(offenders.map { |p| File.basename(p) }).to eq(["http_client.rb"])
    end
  end
end
