# frozen_string_literal: true

require "spec_helper"

# Story 4.1 Tasks 3+4: the bucketing-event enqueue seam (completing 2.11) and the
# explicit flush surface (Client#flush / release_queues -> ApiManager#release_queue).
RSpec.describe "Event-queue wiring (Story 4.1)" do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }

  describe "Context bucketing enqueue (AC#3) — completes the 2.11 seam" do
    let(:store) { ConvertSdk::Stores::MemoryStore.new }
    let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
    let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
    let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
    let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }
    let(:event_manager) { ConvertSdk::EventManager.new(log_manager: log_manager) }

    def stringify(node)
      case node
      when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
      when Array then node.map { |e| stringify(e) }
      else node
      end
    end

    let(:data_manager) do
      dm = ConvertSdk::DataManager.new(
        log_manager: log_manager, data_store_manager: data_store_manager,
        bucketing_manager: bucketing_manager, rule_manager: rule_manager,
        account_resolver: -> { ConfigFixture.account_id },
        project_resolver: -> { ConfigFixture.project_id }
      )
      dm.install_config(stringify(ConfigFixture.config))
      dm
    end

    let(:experience_manager) { ConvertSdk::ExperienceManager.new(data_manager: data_manager, log_manager: log_manager) }

    # A track-endpoint Config so the ApiManager can build a real payload.
    let(:track_config) do
      ConvertSdk::Config.new(
        log_manager: log_manager, data: ConfigFixture.config,
        sdk_key: "sdk-key-1", track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1"
      )
    end
    let(:http_client) { ConvertSdk::HttpClient.new(log_manager: log_manager, open_timeout: 1, read_timeout: 1) }
    let(:api_manager) do
      ConvertSdk::ApiManager.new(
        config: track_config, data_manager: data_manager,
        http_client: http_client, event_manager: event_manager, log_manager: log_manager
      )
    end

    def build_context(visitor_id: "visitor-1", attributes: nil)
      ConvertSdk::Context.new(
        visitor_id: visitor_id, attributes: attributes,
        data_manager: data_manager, data_store_manager: data_store_manager,
        event_manager: event_manager, log_manager: log_manager, config: track_config,
        experience_manager: experience_manager, api_manager: api_manager
      )
    end

    let(:exp_key) { "test-experience-ab-fullstack-2" }
    let(:matching) { { "varName1" => "value1", "varName2" => "value2", "environment" => "staging" } }

    it "enqueues a bucketing event when run_experience buckets the visitor" do
      variation = build_context(attributes: matching).run_experience(exp_key)
      expect(variation).to be_a(ConvertSdk::BucketedVariation)

      drained = api_manager.queue.drain!
      expect(drained.size).to eq(1)
      entry = drained.first
      expect(entry["visitorId"]).to eq("visitor-1")
      expect(entry["events"]).to eq(
        [{
          "eventType" => "bucketing",
          "data" => { "experienceId" => variation.experience_id, "variationId" => variation.id }
        }]
      )
    end

    it "does NOT enqueue on a miss (sentinel)" do
      result = build_context(attributes: { "environment" => "staging" })
               .run_experience(exp_key, varName1: "no", varName2: "no")
      expect(result).to be_a(ConvertSdk::Sentinel)
      expect(api_manager.queue.size).to eq(0)
    end

    it "is inert (no enqueue, no raise) when no api_manager is wired" do
      ctx = ConvertSdk::Context.new(
        visitor_id: "v", attributes: matching,
        data_manager: data_manager, data_store_manager: data_store_manager,
        event_manager: event_manager, log_manager: log_manager, config: track_config,
        experience_manager: experience_manager
      )
      expect { ctx.run_experience(exp_key) }.not_to raise_error
    end
  end

  describe "Client#flush / release_queues (AC#4)" do
    def create(**options)
      ConvertSdk.create(config_endpoint: HttpStubs::CONFIG_HOST, **options)
    end

    let(:direct_data) { { "data" => { "account_id" => "10022898", "project" => { "id" => "10025986" } } } }

    it "drains the queue synchronously through ApiManager#release_queue" do
      client = create(data: direct_data, sdk_key: "sdk-key-1", track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1")
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .with(&capture).to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)

      client.api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      client.flush("manual")

      expect(captured_requests.size).to eq(1)
      expect(client.api_manager.queue.size).to eq(0)
    end

    it "exposes release_queues as a frozen-name alias of flush" do
      client = create(data: direct_data, sdk_key: "sdk-key-1", track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1")
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1")
        .with(&capture).to_return(status: 200, body: JSON.generate(canned_ack), headers: json_headers)

      client.api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))
      client.release_queues("via-alias")

      expect(captured_requests.size).to eq(1)
    end

    it "does not raise on a failed POST (never-crash boundary; 4.2 owns retention)" do
      client = create(data: direct_data, sdk_key: "sdk-key-1", track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1")
      stub_request(:post, "#{HttpStubs::TRACK_HOST}/10025986/v1/track/sdk-key-1").to_return(status: 500, body: "")
      client.api_manager.enqueue("v1", bucketing_event(experience_id: "e1", variation_id: "var1"))

      expect { client.flush }.not_to raise_error
    end

    it "is a safe no-op when the queue is empty" do
      client = create(data: direct_data, sdk_key: "sdk-key-1", track_endpoint: "#{HttpStubs::TRACK_HOST}/[project_id]/v1")
      expect { client.flush }.not_to raise_error
    end
  end
end
