# frozen_string_literal: true

require "spec_helper"

# Story 3.2 — SegmentsManager: visitor segmentation in the JS SDK wire shape.
# put_segments restricts to the seven report-segment keys (the JS SegmentsKeys
# set); select_custom_segments reuses the Epic 2 RuleManager to evaluate a
# segment's rules and attaches matching ids under StoreData["segments"]
# ["customSegments"]. The stored representation is camelCase wire-world strings
# (visitorType/customSegments), NEVER the diverged PHP variants.
RSpec.describe ConvertSdk::SegmentsManager do
  let(:sink) { CapturingSink.new }
  let(:log_manager) { ConvertSdk::LogManager.new(level: ConvertSdk::LogLevel::TRACE, sink: sink) }
  let(:config) { ConvertSdk::Config.new(log_manager: log_manager, data: ConfigFixture.config) }
  let(:store) { ConvertSdk::Stores::MemoryStore.new }
  let(:data_store_manager) { ConvertSdk::DataStoreManager.new(log_manager: log_manager, store: store) }
  let(:bucketing_manager) { ConvertSdk::BucketingManager.new(config: config, log_manager: log_manager) }
  let(:rule_manager) { ConvertSdk::RuleManager.new(config: config, log_manager: log_manager) }

  let(:account_id) { ConfigFixture.account_id }
  let(:project_id) { ConfigFixture.project_id }

  # DataManager loaded with the vendored fixture (direct-data), so the segments
  # reader returns the real ConfigSegment rows (test-config.json carries one
  # segment: key "test-segments-1", id "200299434", rule `enabled == true`).
  let(:data_manager) do
    dm = ConvertSdk::DataManager.new(
      log_manager: log_manager, data_store_manager: data_store_manager,
      bucketing_manager: bucketing_manager, rule_manager: rule_manager,
      account_resolver: -> { account_id }, project_resolver: -> { project_id }
    )
    dm.install_config(stringify(ConfigFixture.config))
    dm
  end

  subject(:manager) do
    described_class.new(
      data_manager: data_manager, data_store_manager: data_store_manager,
      account_resolver: -> { account_id }, project_resolver: -> { project_id },
      rule_manager: rule_manager, log_manager: log_manager
    )
  end

  def stringify(node)
    case node
    when Hash then node.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array then node.map { |e| stringify(e) }
    else node
    end
  end

  # The visitor's persisted StoreData["segments"] map (or {} when unwritten) —
  # the single read seam every assertion reaches through.
  def stored_segments(visitor_id)
    key = data_store_manager.visitor_key(account_id, project_id, visitor_id)
    stored = data_store_manager.get(key)
    stored.is_a?(Hash) ? (stored["segments"] || {}) : {}
  end

  describe "#put_segments — report-segment persistence (AC#1)" do
    it "persists report-segments into StoreData segments (round-trip)" do
      manager.put_segments("v-1", { "country" => "US", "browser" => "chrome" })
      expect(stored_segments("v-1")).to eq("country" => "US", "browser" => "chrome")
    end

    it "merges across calls without clobbering prior report-segments" do
      manager.put_segments("v-merge", { "country" => "US" })
      manager.put_segments("v-merge", { "browser" => "chrome" })
      expect(stored_segments("v-merge")).to eq("country" => "US", "browser" => "chrome")
    end

    it "is a no-op when nothing survives the report-segment filter" do
      manager.put_segments("v-empty", { "plan" => "pro", "tier" => "gold" })
      expect(stored_segments("v-empty")).to eq({})
    end

    # Tabular SegmentsKeys filter — each allowed key survives; disallowed dropped.
    describe "report-segment key filter (data-manager.ts:1180-1199)" do
      ConvertSdk::SegmentsManager::SEGMENTS_KEYS.each do |allowed|
        it "keeps the allowed report key #{allowed.inspect}" do
          manager.put_segments("v-keep", { allowed => "x", "plan" => "pro" })
          expect(stored_segments("v-keep")).to eq(allowed => "x")
        end
      end

      %w[plan tier visitor_type custom_segments environment ruleData].each do |disallowed|
        it "drops the non-report key #{disallowed.inspect}" do
          manager.put_segments("v-drop", { disallowed => "x", "country" => "US" })
          expect(stored_segments("v-drop")).to eq("country" => "US")
        end
      end
    end

    it "debug-logs the dropped non-report keys" do
      manager.put_segments("v-log", { "plan" => "pro", "country" => "US" })
      expect(sink.messages.any? { |l| l.include?("filter_report_segments") && l.include?("plan") }).to be(true)
    end
  end

  describe "#select_custom_segments — rule-driven attachment (AC#2)" do
    # The vendored segment "test-segments-1" matches when ruleData has enabled=true.
    it "attaches a segment id when its rules match the supplied data" do
      manager.select_custom_segments("v-match", ["test-segments-1"], { "enabled" => true })
      expect(stored_segments("v-match")).to eq("customSegments" => ["200299434"])
    end

    it "does NOT attach when the segment rules do not match" do
      manager.select_custom_segments("v-nomatch", ["test-segments-1"], { "enabled" => false })
      expect(stored_segments("v-nomatch")).to eq({})
    end

    it "attaches unconditionally when no segment rule is supplied (JS: !segmentRule)" do
      manager.select_custom_segments("v-norule", ["test-segments-1"], nil)
      expect(stored_segments("v-norule")).to eq("customSegments" => ["200299434"])
    end

    it "dedupes an already-stored segment id across repeated calls" do
      manager.select_custom_segments("v-dup", ["test-segments-1"], { "enabled" => true })
      manager.select_custom_segments("v-dup", ["test-segments-1"], { "enabled" => true })
      expect(stored_segments("v-dup")).to eq("customSegments" => ["200299434"])
    end

    it "warns when re-attaching an already-stored id" do
      manager.select_custom_segments("v-warn", ["test-segments-1"], { "enabled" => true })
      manager.select_custom_segments("v-warn", ["test-segments-1"], { "enabled" => true })
      expect(sink.messages.any? { |l| l.include?("already stored") }).to be(true)
    end

    it "skips an unknown segment key with a debug log (never raises)" do
      result = manager.select_custom_segments("v-unknown", ["no-such-segment"], { "enabled" => true })
      expect(result).to be_nil
      expect(stored_segments("v-unknown")).to eq({})
      expect(sink.messages.any? { |l| l.include?("lookup_segments") && l.include?("no-such-segment") }).to be(true)
    end

    it "returns nil when nothing matched" do
      expect(manager.select_custom_segments("v-none", ["test-segments-1"], { "enabled" => false })).to be_nil
    end

    it "preserves prior customSegments when appending a new matched id" do
      data_store_manager.set(
        data_store_manager.visitor_key(account_id, project_id, "v-prior"),
        { "segments" => { "customSegments" => ["999"] } }
      )
      manager.select_custom_segments("v-prior", ["test-segments-1"], { "enabled" => true })
      expect(stored_segments("v-prior")["customSegments"]).to contain_exactly("999", "200299434")
    end
  end

  describe "wire-key divergence quarantine (AC#3)" do
    # PHP-divergence #2: the diverged PHP wire keys (visitor_type/custom_segments)
    # must NEVER appear in stored segment data — Ruby follows JS verbatim (FR30).
    it "never emits the diverged PHP wire keys" do
      manager.put_segments("v-wire", { "visitorType" => "new" })
      manager.select_custom_segments("v-wire", ["test-segments-1"], { "enabled" => true })

      serialized = JSON.generate(stored_segments("v-wire"))
      expect(serialized).to include("visitorType")
      expect(serialized).to include("customSegments")
      expect(serialized).not_to include("visitor_type")
      expect(serialized).not_to include("custom_segments")
    end

    it "stores customSegments as camelCase string keys at rest" do
      manager.select_custom_segments("v-rest", ["test-segments-1"], { "enabled" => true })
      expect(stored_segments("v-rest").keys).to eq(["customSegments"])
    end
  end
end
