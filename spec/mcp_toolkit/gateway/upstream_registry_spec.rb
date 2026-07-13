# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Gateway::UpstreamRegistry do
  subject(:registry) { described_class.new }

  describe "#register" do
    it "registers an upstream by key, exposed via #find and #all" do
      registry.register(key: "notifications", url: "http://notifications.test/mcp")

      upstream = registry.find("notifications")
      expect(upstream.key).to eq("notifications")
      expect(upstream.url).to eq("http://notifications.test/mcp")
      expect(registry.all).to eq([upstream])
    end

    it "defaults public_tool_list to true (upstream opts into the shared list cache)" do
      registry.register(key: "notifications", url: "http://notifications.test/mcp")

      expect(registry.find("notifications").public_tool_list).to be(true)
    end

    it "registers a caller-dependent upstream with public_tool_list: false" do
      registry.register(key: "gateway", url: "http://gateway.test/mcp", public_tool_list: false)

      expect(registry.find("gateway").public_tool_list).to be(false)
    end

    it "normalizes a symbol key to a string" do
      registry.register(key: :notifications, url: "http://notifications.test/mcp")

      expect(registry.find(:notifications)).to eq(registry.find("notifications"))
      expect(registry.find("notifications").key).to eq("notifications")
    end

    it "ignores a blank url so an unconfigured ENV lookup is a no-op" do
      registry.register(key: "notifications", url: nil)
      registry.register(key: "billing", url: "")

      expect(registry.all).to be_empty
    end

    it "preserves insertion order in #all" do
      registry.register(key: "a", url: "http://a.test")
      registry.register(key: "b", url: "http://b.test")

      expect(registry.all.map(&:key)).to eq(%w[a b])
    end
  end

  describe "#reset!" do
    it "clears every registered upstream" do
      registry.register(key: "notifications", url: "http://notifications.test/mcp")

      registry.reset!

      expect(registry.all).to be_empty
      expect(registry.find("notifications")).to be_nil
    end
  end

  describe "#split_tool_name" do
    before { registry.register(key: "notifications", url: "http://notifications.test/mcp") }

    it "splits a namespaced name into [key, bare] for a registered upstream" do
      expect(registry.split_tool_name("notifications__list_items")).to eq(["notifications", "list_items"])
    end

    it "returns nil for an un-namespaced name" do
      expect(registry.split_tool_name("list_items")).to be_nil
    end

    it "returns nil when the key is not registered" do
      expect(registry.split_tool_name("billing__list_items")).to be_nil
    end

    it "returns nil when the bare tool name is empty" do
      expect(registry.split_tool_name("notifications__")).to be_nil
    end
  end

  describe "Upstream#name_for" do
    it "namespaces a bare tool name as `<key>__<tool>`" do
      upstream = described_class::Upstream.new(key: "notifications", url: "http://notifications.test/mcp")

      expect(upstream.name_for("list_items")).to eq("notifications__list_items")
    end
  end

  describe "the per-config instance + sugar" do
    it "exposes a fresh registry per config as `config.upstreams`" do
      expect(McpToolkit.config.upstreams).to be_a(described_class)
      expect(McpToolkit.config.upstreams.all).to be_empty
    end

    it "delegates `config.register_upstream` to `config.upstreams.register`" do
      McpToolkit.config.register_upstream(key: "notifications", url: "http://notifications.test/mcp")

      expect(McpToolkit.config.upstreams.find("notifications").url).to eq("http://notifications.test/mcp")
    end

    it "is reset by reset_config! (test isolation)" do
      McpToolkit.config.register_upstream(key: "notifications", url: "http://notifications.test/mcp")

      McpToolkit.reset_config!

      expect(McpToolkit.config.upstreams.all).to be_empty
    end
  end

  describe "config.register_upstreams_from_env" do
    it "registers every upstream whose ENV url is present, skipping blanks" do
      McpToolkit.config.register_upstreams_from_env(
        { "notifications" => "NOTIF_URL", "billing" => "BILLING_URL", "empty" => "EMPTY_URL" },
        env: { "NOTIF_URL" => "http://notif.test/mcp", "BILLING_URL" => "http://billing.test/mcp", "EMPTY_URL" => "" }
      )

      expect(McpToolkit.config.upstreams.all.map(&:key)).to eq(%w[notifications billing])
    end

    it "resets the registry first (idempotent across code reloads)" do
      McpToolkit.config.register_upstream(key: "stale", url: "http://stale.test/mcp")

      McpToolkit.config.register_upstreams_from_env(
        { "notifications" => "NOTIF_URL" }, env: { "NOTIF_URL" => "http://notif.test/mcp" }
      )
      McpToolkit.config.register_upstreams_from_env(
        { "notifications" => "NOTIF_URL" }, env: { "NOTIF_URL" => "http://notif.test/mcp" }
      )

      expect(McpToolkit.config.upstreams.all.map(&:key)).to eq(%w[notifications])
    end
  end
end
