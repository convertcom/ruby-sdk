# frozen_string_literal: true

require "spec_helper"

# Story 2.7 — config caching, background refresh, lazy-TTL fallback.
#
# These specs drive the refresh surface deterministically: timer ticks are
# invoked by calling the Client's refresh entry point directly (no real sleeps),
# the monotonic clock is stubbed so TTL staleness is controlled without time
# passing, and WebMock sequenced stubs simulate config v1 -> v2 -> outage.
RSpec.describe "ConvertSdk::Client config refresh (Story 2.7)" do
  let(:base_options) { { config_endpoint: HttpStubs::CONFIG_HOST } }

  # A controllable monotonic clock: tests advance it explicitly so TTL math is
  # deterministic and free of real waits.
  class FakeClock
    def initialize(now = 1000.0)
      @now = now
    end

    def call
      @now
    end

    def advance(seconds)
      @now += seconds
    end
  end

  # Build a client through the real public factory with test-host endpoints and
  # an injected fake clock (so DataManager's TTL math is controllable).
  def create(clock: nil, **options)
    ConvertSdk.create(**base_options, clock: clock, **options)
  end

  # The byte-exact config cache key for the default test sdk key.
  def config_key(sdk_key = "sdk-key-1")
    "convert_sdk.config.#{sdk_key}"
  end

  # A second config body distinct from the vendored one, to assert a swap.
  def updated_config
    { "environment" => "production", "data" => { "account_id" => "ACCT-2", "experiences" => [] } }
  end

  describe "Task 1 — config cache in the storage port (AC#1)" do
    it "writes the fetched config under convert_sdk.config.{sdkKey} on install" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      entry = client.instance_variable_get(:@data_store_manager).get(config_key)
      expect(entry).to be_a(Hash)
      expect(entry["config"]).to be_a(Hash)
      expect(entry["config"]["data"]["account_id"]).to eq("10022898")
    end

    it "records a fetched-at wall-clock timestamp alongside the cached config" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      entry = client.instance_variable_get(:@data_store_manager).get(config_key)
      expect(entry["fetched_at"]).to be_a(Float)
    end

    it "logs at info when serving a non-stale cached entry on init fetch failure" do
      store = ConvertSdk::Stores::MemoryStore.new
      store.set(config_key, { "config" => updated_config, "fetched_at" => Time.now.to_f })
      sink = CapturingSink.new
      log_manager = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
      stub_vendored_config(sdk_key: "sdk-key-1", status: 500)
      client = build_client(store: store, log_manager: log_manager, sdk_key: "sdk-key-1")
      expect(client.config_available?).to be(true)
      expect(client.data_manager.account_id).to eq("ACCT-2")
      expect(sink.joined).to match(/serving cached config/i)
    end

    it "does NOT fall back to a stale cached entry on init fetch failure" do
      store = ConvertSdk::Stores::MemoryStore.new
      stale_at = Time.now.to_f - (ConvertSdk::DEFAULT_CONFIG_TTL + 10)
      store.set(config_key, { "config" => updated_config, "fetched_at" => stale_at })
      stub_vendored_config(sdk_key: "sdk-key-1", status: 500)
      client = build_client(store: store, sdk_key: "sdk-key-1")
      expect(client.config_available?).to be(false)
    end
  end

  describe "Task 2 — lazily-started refresh timer (AC#2)" do
    it "does NOT start the refresh timer in the factory" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      expect(refresh_timer(client).alive?).to be(false)
    end

    it "starts the refresh timer on the first ensure_refresh_timer! call" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      client.ensure_refresh_timer!
      expect(refresh_timer(client).alive?).to be(true)
      client.ensure_refresh_timer! # idempotent
      stop_timer(client)
    end

    it "registers the refresh timer with ForkGuard" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1")
      registered = ConvertSdk::ForkGuard.instance_variable_get(:@timers)
      expect(registered).to include(refresh_timer(client))
    end

    it "refetches, atomically swaps the frozen snapshot, and fires config.updated on a tick" do
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_return(status: 200, body: JSON.generate(updated_config), headers: json_headers)
      client = create(sdk_key: "sdk-key-1")
      updated = 0
      client.on(ConvertSdk::SystemEvents::CONFIG_UPDATED) { updated += 1 }
      tick_refresh(client)
      expect(client.data_manager.account_id).to eq("ACCT-2")
      expect(updated).to eq(1)
      expect(DeepFrozen.deep_frozen?(client.data_manager.experiences)).to be(true)
    end

    it "does NOT re-fire ready on a refresh tick" do
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_return(status: 200, body: JSON.generate(updated_config), headers: json_headers)
      client = create(sdk_key: "sdk-key-1")
      ready = 0
      client.on(ConvertSdk::SystemEvents::READY) { ready += 1 }
      tick_refresh(client)
      expect(ready).to eq(1) # the deferred replay to the late subscriber, once
    end

    it "never creates a refresh timer when data_refresh_interval is nil" do
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1", data_refresh_interval: nil)
      client.ensure_refresh_timer!
      expect(refresh_timer(client).alive?).to be(false)
    end
  end

  describe "Task 3 — lazy-TTL fallback, timer-off mode (AC#3)" do
    it "does NOT refetch at decision time when the cached config is fresh" do
      clock = FakeClock.new
      stub_vendored_config(sdk_key: "sdk-key-1")
      client = create(sdk_key: "sdk-key-1", data_refresh_interval: nil, clock: clock)
      reset_http_capture
      client.ensure_fresh_config!
      expect(captured_requests).to be_empty
    end

    it "synchronously refetches before deciding when the cached config is stale" do
      clock = FakeClock.new
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_return(status: 200, body: JSON.generate(updated_config), headers: json_headers)
      client = create(sdk_key: "sdk-key-1", data_refresh_interval: nil, clock: clock)
      clock.advance(ConvertSdk::DEFAULT_CONFIG_TTL + 1)
      client.ensure_fresh_config!
      expect(client.data_manager.account_id).to eq("ACCT-2")
    end

    it "serves the stale config (and warns) when the synchronous refetch fails" do
      clock = FakeClock.new
      sink = CapturingSink.new
      log_manager = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_timeout
      client = build_client(log_manager: log_manager, sdk_key: "sdk-key-1",
                            data_refresh_interval: nil, clock: clock)
      clock.advance(ConvertSdk::DEFAULT_CONFIG_TTL + 1)
      client.ensure_fresh_config!
      expect(client.data_manager.account_id).to eq("10022898")
      expect(sink.joined).to match(/refresh failed, serving cached config/i)
    end

    it "performs only ONE fetch under concurrent stale decisions (thundering-herd guard)" do
      clock = FakeClock.new
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_return(status: 200, body: JSON.generate(updated_config), headers: json_headers)
      client = create(sdk_key: "sdk-key-1", data_refresh_interval: nil, clock: clock)
      clock.advance(ConvertSdk::DEFAULT_CONFIG_TTL + 1)
      reset_http_capture
      threads = Array.new(8) { Thread.new { client.ensure_fresh_config! } }
      threads.each(&:join)
      expect(captured_requests.size).to eq(1)
    end
  end

  describe "Task 4 — refresh failure resilience (AC#4)" do
    it "keeps serving the current snapshot and warns when a refresh tick fails" do
      sink = CapturingSink.new
      log_manager = ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink)
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_timeout
      client = build_client(log_manager: log_manager, sdk_key: "sdk-key-1")
      updated = 0
      client.on(ConvertSdk::SystemEvents::CONFIG_UPDATED) { updated += 1 }
      tick_refresh(client)
      expect(client.data_manager.account_id).to eq("10022898")
      expect(updated).to eq(0)
      expect(sink.joined).to match(/Client#refresh_config: refresh failed, serving cached config/)
    end

    it "retries on the next tick after a failed refresh (no backoff state)" do
      stub_request(:get, %r{/config/sdk-key-1})
        .to_return(status: 200, body: JSON.generate(vendored_config), headers: json_headers).then
        .to_timeout.then
        .to_return(status: 200, body: JSON.generate(updated_config), headers: json_headers)
      client = create(sdk_key: "sdk-key-1")
      tick_refresh(client) # fails, keeps old
      expect(client.data_manager.account_id).to eq("10022898")
      tick_refresh(client) # succeeds on the very next tick
      expect(client.data_manager.account_id).to eq("ACCT-2")
    end
  end

  # --- shared helpers (kept here to avoid per-example duplication) ----------

  # Build a Client through the factory with an explicit store and/or log_manager.
  # ConvertSdk.create does not accept a log_manager, so we wire the managers in
  # the same order the factory does when a custom log_manager is needed.
  def build_client(store: nil, log_manager: nil, sdk_key:, **options)
    return create(sdk_key: sdk_key, store: store, **options) if log_manager.nil?

    config_options = options.merge(sdk_key: sdk_key, config_endpoint: HttpStubs::CONFIG_HOST)
    clock = config_options.delete(:clock)
    config = ConvertSdk::Config.new(log_manager: log_manager, **config_options)
    http_client = ConvertSdk::HttpClient.new(log_manager: log_manager,
                                             open_timeout: config.open_timeout,
                                             read_timeout: config.read_timeout)
    dsm = ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store)
    event_manager = ConvertSdk::EventManager.new(log_manager: log_manager)
    dm_options = clock.nil? ? {} : { clock: clock }
    data_manager = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: dsm,
      config_key: dsm.config_key(sdk_key), ttl: config.data_refresh_interval, **dm_options
    )
    ConvertSdk::Client.new(config: config, log_manager: log_manager, http_client: http_client,
                          data_store_manager: dsm, event_manager: event_manager,
                          data_manager: data_manager)
  end

  # The Client's refresh BackgroundTimer instance.
  def refresh_timer(client)
    client.instance_variable_get(:@refresh_timer)
  end

  # Drive one refresh tick deterministically (no real sleep).
  def tick_refresh(client)
    client.send(:refresh_config)
  end

  # Stop a started timer so no thread leaks across examples.
  def stop_timer(client)
    refresh_timer(client)&.stop
  end
end
