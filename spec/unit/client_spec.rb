# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConvertSdk::Client do
  # All clients fetch against the opaque test config host (never the real CDN).
  let(:base_options) { { config_endpoint: HttpStubs::CONFIG_HOST } }

  # Build a client through the real public factory with test-host endpoints.
  def create(**options)
    ConvertSdk.create(**base_options, **options)
  end

  describe "fetch mode — config fetch via HttpClient (AC#1)" do
    it "fetches GET {config_endpoint}/config/{sdkKey} and installs the config" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      expect(client.config_available?).to be(true)
      # Compare path+query (WebMock normalises the host with an explicit :443).
      expect(URI.parse(captured_request.uri).request_uri).to eq("/config/sdk-key-1")
    end

    it "appends ?environment=... when an environment is configured" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      create(sdk_key: "sdk-key-1", environment: "staging")
      expect(URI.parse(captured_request.uri).request_uri).to eq("/config/sdk-key-1?environment=staging")
    end

    it "omits the environment parameter when none is configured" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      create(sdk_key: "sdk-key-1")
      expect(captured_request.uri).not_to include("environment")
    end

    it "attaches Authorization: Bearer when an sdk_key_secret is configured" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      create(sdk_key: "sdk-key-1", sdk_key_secret: "shh-secret")
      expect(captured_request.headers["Authorization"]).to eq("Bearer shh-secret")
    end

    it "omits Authorization when no secret is configured" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      create(sdk_key: "sdk-key-1")
      expect(captured_request.headers).not_to have_key("Authorization")
    end

    it "exposes the fetched config through DataManager readers" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      expect(client.data_manager.account_id).to eq("10022898")
      expect(client.data_manager.project_id).to eq("10025986")
    end
  end

  describe "direct data mode — no fetch (AC#2)" do
    let(:direct_data) { JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__))) }

    it "makes ZERO HTTP requests when data is supplied" do
      client = create(data: direct_data)
      expect(a_request(:any, /.*/)).not_to have_been_made
      expect(client.config_available?).to be(true)
    end

    it "installs the supplied config so readers expose it" do
      client = create(data: direct_data)
      expect(client.data_manager.account_id).to eq("10022898")
      expect(client.data_manager.experiences.size).to eq(direct_data["data"]["experiences"].size)
    end

    it "normalises a symbol-keyed data object to string keys at the boundary" do
      symbol_keyed = { environment: "staging", data: { account_id: "777", experiences: [] } }
      client = create(data: symbol_keyed)
      expect(client.data_manager.account_id).to eq("777")
      expect(client.data_manager.experiences).to eq([])
    end
  end

  describe "degrade-gracefully on fetch failure (AC#5)" do
    it "does not raise and constructs a config-less client on a failed fetch" do
      stub_vendored_config(sdk_key: "sdk-key-1", status: 500)
      client = nil
      expect { client = create(sdk_key: "sdk-key-1") }.not_to raise_error
      expect(client.config_available?).to be(false)
    end

    it "does not raise and is config-less on a transport error" do
      stub_request(:get, %r{/config/sdk-key-1}).to_timeout
      client = nil
      expect { client = create(sdk_key: "sdk-key-1") }.not_to raise_error
      expect(client.config_available?).to be(false)
    end
  end

  describe "ready fires exactly once (AC#4)" do
    it "fires ready on the first successful install (fetched config)" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      fired = []
      client.on(ConvertSdk::SystemEvents::READY) { |_p, _e| fired << :ready }
      expect(fired).to eq([:ready]) # deferred replay to the late subscriber
    end

    it "fires ready on the first successful install (direct data)" do
      client = create(data: { "data" => { "account_id" => "1" } })
      fired = []
      client.on("ready") { fired << :ready }
      expect(fired).to eq([:ready])
    end

    it "does not fire ready when the first fetch fails" do
      stub_vendored_config(sdk_key: "sdk-key-1", status: 500)
      client = create(sdk_key: "sdk-key-1")
      fired = []
      client.on(ConvertSdk::SystemEvents::READY) { fired << :ready }
      expect(fired).to eq([])
    end

    it "fires config.updated (never ready again) on a subsequent install" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      ready_count = 0
      updated_count = 0
      client.on(ConvertSdk::SystemEvents::READY) { ready_count += 1 }
      client.on(ConvertSdk::SystemEvents::CONFIG_UPDATED) { updated_count += 1 }
      # The first install already happened during construction (ready once,
      # replayed to the late subscriber above). A second install through the
      # Client's own install path is Story 2.7's refresh — it must fire
      # config.updated, never ready again.
      client.send(:install, { "data" => { "account_id" => "2" } }, "refresh")
      expect(ready_count).to eq(1)
      expect(updated_count).to eq(1)
    end
  end

  describe "public surface" do
    it "#on returns self for chaining and never raises on a bad listener" do
      client = create(data: { "data" => {} })
      expect(client.on("ready")).to be(client)
    end
  end

  describe "#create_context (Story 2.8 — AC#1, AC#2)" do
    let(:direct_data) { JSON.parse(File.read(File.expand_path("../fixtures/test-config.json", __dir__))) }

    it "returns a Context bound to the visitor id and attributes" do
      ctx = create(data: direct_data).create_context("visitor-9", country: "US")
      expect(ctx).to be_a(ConvertSdk::Context)
      expect(ctx.visitor_id).to eq("visitor-9")
      expect(ctx.attributes).to eq({ "country" => "US" })
    end

    it "returns a NEW independent Context on each call (no caching, FR12)" do
      client = create(data: direct_data)
      a = client.create_context("v-a")
      b = client.create_context("v-b")
      expect(a).not_to be(b)
      a.update_visitor_properties(plan: "pro")
      expect(b.attributes).to eq({})
    end

    it "fires the lazy-start refresh-timer hook on context creation (first use)" do
      client = create(data: direct_data)
      allow(client).to receive(:ensure_refresh_timer!).and_call_original
      client.create_context("visitor-9")
      expect(client).to have_received(:ensure_refresh_timer!)
    end

    it "logs an error and returns nil for a nil visitor id (never-crash, not ArgumentError)" do
      client = create(data: direct_data)
      result = nil
      expect { result = client.create_context(nil) }.not_to raise_error
      expect(result).to be_nil
    end

    it "logs an error and returns nil for a blank visitor id" do
      expect(create(data: direct_data).create_context("   ")).to be_nil
    end

    it "logs an error and returns nil when the lazy-start hook raises (never-crash)" do
      client = create(data: direct_data)
      allow(client).to receive(:ensure_refresh_timer!).and_raise(StandardError, "boom")
      result = "unset"
      expect { result = client.create_context("v") }.not_to raise_error
      expect(result).to be_nil
    end
  end

  describe "never-crash boundary" do
    let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: CapturingSink.new) }
    let(:config) { ConvertSdk::Config.new(data: { "data" => {} }, config_endpoint: HttpStubs::CONFIG_HOST) }

    # Build a Client with one collaborator replaced by a raising double, to
    # exercise the rescue boundaries directly.
    def client_with(event_manager: nil, data_manager: nil)
      http_client = ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1)
      em = event_manager || ConvertSdk::EventManager.new(log_manager: log_manager)
      dm = data_manager || ConvertSdk::DataManager.new(log_manager: log_manager)
      described_class.new(
        config: config,
        log_manager: log_manager,
        http_client: http_client,
        data_store_manager: ConvertSdk::DataStoreManager.new(log_manager: log_manager),
        event_manager: em,
        data_manager: dm,
        api_manager: ConvertSdk::ApiManager.new(
          config: config, data_manager: dm,
          http_client: http_client, event_manager: em, log_manager: log_manager
        )
      )
    end

    it "does not raise from #initialize when a collaborator raises during bootstrap" do
      raising_dm = instance_double(ConvertSdk::DataManager)
      # The Client wires the timer-off refresh callable into the DataManager
      # before bootstrap (Story 2.7); allow that setter on the double.
      allow(raising_dm).to receive(:refetch=)
      allow(raising_dm).to receive(:install_config).and_raise(StandardError, "boom")
      expect { client_with(data_manager: raising_dm) }.not_to raise_error
    end

    it "does not raise from #on when the event manager raises, and still returns self" do
      raising_em = instance_double(ConvertSdk::EventManager)
      allow(raising_em).to receive(:fire) # bootstrap fires ready; let it pass
      allow(raising_em).to receive(:on).and_raise(StandardError, "boom")
      client = client_with(event_manager: raising_em)
      result = nil
      expect { result = client.on("ready") }.not_to raise_error
      expect(result).to be(client)
    end
  end
end
