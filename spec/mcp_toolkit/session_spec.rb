# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Session do
  # The default config ships an ActiveSupport::Cache::MemoryStore, which is enough
  # to exercise create/find/delete + sliding TTL behavior.
  describe ".create!" do
    it "mints an opaque id and persists the session in the cache" do
      session = described_class.create!

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
      id = described_class.create!.id

      expect(described_class.find(id).id).to eq(id)
    end

    it "slides the TTL on every successful lookup" do
      session = described_class.create!
      McpToolkit.config.session_ttl = 100

      expect(McpToolkit.config.cache_store).to receive(:write).with(
        "#{described_class::CACHE_KEY_PREFIX}#{session.id}", anything, expires_in: 100
      ).and_call_original

      described_class.find(session.id)
    end
  end

  describe ".delete" do
    it "removes the session" do
      id = described_class.create!.id

      described_class.delete(id)

      expect(described_class.find(id)).to be_nil
    end

    it "is a no-op for a blank id" do
      expect(described_class.delete(nil)).to be(false)
    end
  end
end
