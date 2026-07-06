# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit do
  subject(:mcp_toolkit) { described_class }

  it "has a version number" do
    expect(McpToolkit::VERSION).not_to be_nil
  end

  it "exposes MCPToolkit as an alias of McpToolkit" do
    expect(MCPToolkit).to equal(mcp_toolkit)
  end

  describe ".configure" do
    it "yields the active configuration and returns it" do
      returned = mcp_toolkit.configure do |c|
        c.server_name = "configured-mcp"
        c.registry.default_required_permissions_scope "thing__read"
      end

      expect(returned).to be(mcp_toolkit.config)
      expect(mcp_toolkit.config.server_name).to eq("configured-mcp")
      expect(mcp_toolkit.config.registry.default_required_permissions_scope).to eq("thing__read")
    end
  end

  describe ".config defaults" do
    subject(:config) { described_class.config }

    it "ships opinionated, vendor-neutral defaults" do
      expect(config.introspect_path).to eq("/mcp/tokens/introspect")
      expect(config.account_meta_key).to eq("mcp-toolkit/account-id")
      expect(config.account_id_header).to eq("X-MCP-Account-ID")
      expect(config.session_ttl).to eq(3600)
      expect(config.serializer_base).to eq(McpToolkit::Serializer::Base)
    end

    it "ships vendor-neutral gateway + diagnostics defaults" do
      expect(config.upstream_timeout).to eq(10)
      expect(config.upstream_list_ttl).to eq(900)
      expect(config.logger).to be_nil
      expect(config.upstreams).to be_a(McpToolkit::Gateway::UpstreamRegistry)
      expect(config.upstreams.all).to be_empty
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
      expect(mcp_toolkit.registry).to be(mcp_toolkit.config.registry)
    end
  end
end
