# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Session do
  # The default config ships an ActiveSupport::Cache::MemoryStore, which is enough
  # to exercise create/find/delete + sliding TTL behavior.
  subject(:session) { described_class.create! }

  describe ".create!" do
    it "mints an opaque id and persists the session in the cache" do
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
      expect(described_class.find(session.id)).to be_a(described_class)
    end
  end

  describe ".find" do
    it "returns nil for a blank or unknown id" do
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
      expect(described_class.find("does-not-exist")).to be_nil
    end

    it "returns a session for a known id" do
      id = session.id

      expect(described_class.find(id).id).to eq(id)
    end

    it "slides the TTL on every successful lookup" do
      McpToolkit.config.session_ttl = 100

      expect(McpToolkit.config.cache_store).to receive(:write).with(
        "mcp_toolkit:session:#{session.id}", anything, expires_in: 100
      ).and_call_original

      described_class.find(session.id)
    end
  end

  describe ".delete" do
    it "removes the session" do
      id = session.id

      described_class.delete(id)

      expect(described_class.find(id)).to be_nil
    end

    it "is a no-op for a blank id" do
      expect(described_class.delete(nil)).to be(false)
    end
  end

  describe "opaque data payload" do
    it "defaults #data to {} when none is supplied on create" do
      expect(described_class.create!.data).to eq({})
    end

    it "round-trips an opaque data payload through create -> find" do
      created = described_class.create!(data: { token_id: 99 })

      expect(created.data).to eq(token_id: 99)
      expect(described_class.find(created.id).data).to eq(token_id: 99)
    end

    it "defaults #data to {} for a legacy row written without the payload" do
      # Simulate a pre-`data` cache row: only created_at, no :data key.
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write(
        "mcp_toolkit:session:#{id}", { created_at: Time.now.to_i }
      )

      expect(described_class.find(id).data).to eq({})
    end

    it "preserves the data payload across the sliding-TTL rewrite on find" do
      created = described_class.create!(data: { token_id: 7 })

      described_class.find(created.id) # slides TTL, rewrites the row
      expect(described_class.find(created.id).data).to eq(token_id: 7)
    end
  end

  describe "host-compat session store (key prefix + payload codec)" do
    # A host migrating a PRE-GEM session store keeps its historical namespace and
    # wire format, so old and new application versions share live sessions during
    # a rolling deploy.
    before do
      McpToolkit.configure do |c|
        c.session_key_prefix = "legacy:session:"
        c.session_payload_dumper = ->(data) { { legacy_token_id: data[:token_id] } }
        c.session_payload_loader = ->(stored) { { token_id: stored[:legacy_token_id] } }
      end
    end

    it "stores under the configured prefix in the configured wire format" do
      created = described_class.create!(data: { token_id: 42 })

      raw = McpToolkit.config.cache_store.read("legacy:session:#{created.id}")
      expect(raw).to eq(legacy_token_id: 42)
    end

    it "finds a session written by a PRE-GEM instance (the legacy format)" do
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write("legacy:session:#{id}", { legacy_token_id: 7 })

      expect(described_class.find(id).data).to eq(token_id: 7)
    end

    it "re-writes the RAW legacy payload on the sliding-TTL bump (old instances keep reading it)" do
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write("legacy:session:#{id}", { legacy_token_id: 7 })

      described_class.find(id)

      expect(McpToolkit.config.cache_store.read("legacy:session:#{id}")).to eq(legacy_token_id: 7)
    end

    it "deletes under the configured prefix" do
      created = described_class.create!(data: { token_id: 42 })

      described_class.delete(created.id)

      expect(McpToolkit.config.cache_store.read("legacy:session:#{created.id}")).to be_nil
    end
  end

  describe "declarative session_payload_key_map (flat legacy format)" do
    before do
      McpToolkit.configure do |c|
        c.session_key_prefix = "legacy:session:"
        c.session_payload_key_map = { token_id: :legacy_token_id }
      end
    end

    it "stores the data hash FLAT with renamed keys (no created_at/data envelope)" do
      created = described_class.create!(data: { token_id: 42 })

      expect(McpToolkit.config.cache_store.read("legacy:session:#{created.id}")).to eq(legacy_token_id: 42)
    end

    it "reads a legacy row back into the data keys" do
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write("legacy:session:#{id}", { legacy_token_id: 7 })

      expect(described_class.find(id).data).to eq(token_id: 7)
    end

    it "symbolizes string-keyed rows (a JSON-coded cache store still round-trips)" do
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write("legacy:session:#{id}", { "legacy_token_id" => 7 })

      expect(described_class.find(id).data).to eq(token_id: 7)
    end

    it "passes unmapped keys through unchanged in both directions" do
      created = described_class.create!(data: { token_id: 42, locale: "fr" })

      expect(McpToolkit.config.cache_store.read("legacy:session:#{created.id}"))
        .to eq(legacy_token_id: 42, locale: "fr")
      expect(described_class.find(created.id).data).to eq(token_id: 42, locale: "fr")
    end

    it "tolerates a malformed (non-Hash) stored row" do
      id = SecureRandom.uuid
      McpToolkit.config.cache_store.write("legacy:session:#{id}", "corrupt")

      expect(described_class.find(id).data).to eq({})
    end

    it "yields to an explicit dumper/loader pair when both are configured" do
      McpToolkit.configure do |c|
        c.session_payload_dumper = ->(data) { { custom: data[:token_id] } }
        c.session_payload_loader = ->(stored) { { token_id: stored[:custom] } }
      end

      created = described_class.create!(data: { token_id: 9 })

      expect(McpToolkit.config.cache_store.read("legacy:session:#{created.id}")).to eq(custom: 9)
      expect(described_class.find(created.id).data).to eq(token_id: 9)
    end
  end
end
