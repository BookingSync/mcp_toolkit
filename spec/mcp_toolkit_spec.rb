# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit do
  it "has a version number" do
    expect(McpToolkit::VERSION).not_to be_nil
  end

  it "exposes MCPToolkit as an alias of McpToolkit" do
    expect(MCPToolkit).to equal(described_class)
  end

  describe ".configure" do
    it "yields the active configuration and returns it" do
      returned = described_class.configure do |c|
        c.server_name = "configured-mcp"
        c.required_application = "thing"
      end

      expect(returned).to be(described_class.config)
      expect(described_class.config.server_name).to eq("configured-mcp")
      expect(described_class.config.required_application).to eq("thing")
    end
  end

  describe ".config defaults" do
    subject(:config) { described_class.config }

    it "ships opinionated defaults matching the two source apps" do
      expect(config.introspect_path).to eq("/mcp/tokens/introspect")
      expect(config.account_meta_key).to eq("bookingsync.com/account-id")
      expect(config.account_id_header).to eq("X-BookingSync-Account-ID")
      expect(config.session_ttl).to eq(3600)
      expect(config.serializer_base).to eq(McpToolkit::Serializer::Base)
    end

    it "defaults the account_resolver to identity" do
      expect(config.account_resolver.call(42)).to eq(42)
    end

    it "raises a clear error when introspect_url is needed but central_app_url is unset" do
      expect { config.introspect_url }
        .to raise_error(McpToolkit::Errors::ConfigurationError, /central_app_url/)
    end
  end

  describe ".registry" do
    it "delegates to the active config's registry" do
      expect(described_class.registry).to be(described_class.config.registry)
    end
  end
end
