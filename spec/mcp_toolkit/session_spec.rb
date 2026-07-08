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
        "#{described_class::CACHE_KEY_PREFIX}#{session.id}", anything, expires_in: 100
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
        "#{described_class::CACHE_KEY_PREFIX}#{id}", { created_at: Time.now.to_i }
      )

      expect(described_class.find(id).data).to eq({})
    end

    it "preserves the data payload across the sliding-TTL rewrite on find" do
      created = described_class.create!(data: { token_id: 7 })

      described_class.find(created.id) # slides TTL, rewrites the row
      expect(described_class.find(created.id).data).to eq(token_id: 7)
    end
  end
end
