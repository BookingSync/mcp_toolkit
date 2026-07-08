# frozen_string_literal: true

require "spec_helper"

# Gateway behaviour of the authority dispatcher: aggregating + proxying upstream
# MCP tools. The gateway machinery itself is unit-tested under gateway/*; this
# pins how the DISPATCHER wires to it — list merge, account-id + bearer
# forwarding, upstream error translation, and the list_changed cache flush —
# mocking only the gem's gateway boundary. Ported from core's server_gateway_spec.
RSpec.describe McpToolkit::Dispatcher do
  subject(:dispatcher) { described_class.new(context:, config: McpToolkit.config) }

  let(:account) { FakeAccount.new(42) }
  let(:principal) { FakePrincipal.new(scopes: []) }
  let(:context) { McpToolkit::Authority::Context.new(account:, principal:, bearer_token: "mcp_caller_token") }

  let(:host_tool) { FakeTool.new(result: { ok: true }) }
  let(:provider) { FakeToolProvider.new(tools: { "host_list" => host_tool }) }

  let(:upstream) { McpToolkit::Gateway::UpstreamRegistry::Upstream.new(key: "notifications", url: "https://notif.test/mcp") }

  before { McpToolkit.config.tool_provider = provider }

  def request(method, params = {}, id: 1)
    body = { "jsonrpc" => "2.0", "method" => method, "params" => params }
    id.nil? ? body : body.merge("id" => id)
  end

  describe "tools/list aggregation" do
    let(:aggregator) { instance_double(McpToolkit::Gateway::Aggregator) }

    before do
      allow(McpToolkit::Gateway::Aggregator).to receive(:new).and_return(aggregator)
      allow(aggregator).to receive(:tool_definitions).with(bearer_token: "mcp_caller_token").and_return(
        [
          { "name" => "notifications__send_email", "description" => "Send", "inputSchema" => { "type" => "object" } },
          { "name" => "owners__list", "description" => "List", "inputSchema" => { "type" => "object" } }
        ]
      )
    end

    it "returns the host's own tools plus the namespaced upstream tools" do
      names = dispatcher.handle_request(request("tools/list"))[:result][:tools].map { |t| t[:name] || t["name"] }

      expect(names).to include("host_list") # the host's own tool
      expect(names).to include("notifications__send_email", "owners__list")
    end
  end

  describe "tools/list when the upstream is down" do
    let(:aggregator) { instance_double(McpToolkit::Gateway::Aggregator, tool_definitions: []) }

    before { allow(McpToolkit::Gateway::Aggregator).to receive(:new).and_return(aggregator) }

    it "still returns the host's own tools (the aggregator degrades to [])" do
      names = dispatcher.handle_request(request("tools/list"))[:result][:tools].map { |t| t[:name] || t["name"] }

      expect(names).to include("host_list")
      expect(names.none? { |n| n.start_with?("notifications__") }).to be(true)
    end
  end

  describe "tools/call routing" do
    let(:proxy) { instance_double(McpToolkit::Gateway::Proxy) }

    before do
      McpToolkit.config.upstreams.register(key: upstream.key, url: upstream.url)
      allow(McpToolkit::Gateway::Proxy).to receive(:new).and_return(proxy)
    end

    it "proxies a namespaced tool, forwarding the resolved account id + bearer" do
      allow(proxy).to receive(:call).and_return({ "content" => [{ "type" => "text", "text" => "sent" }] })

      response = dispatcher.handle_request(
        request("tools/call", { "name" => "notifications__send_email", "arguments" => { "to" => "a@b.c" } })
      )

      expect(response[:result]).to eq({ "content" => [{ "type" => "text", "text" => "sent" }] })
      expect(McpToolkit::Gateway::Proxy).to have_received(:new).with(
        app_key: "notifications",
        tool_name: "send_email",
        account_id: 42,
        bearer_token: "mcp_caller_token",
        config: McpToolkit.config
      )
      expect(proxy).to have_received(:call).with({ "to" => "a@b.c" })
    end

    it "falls through to a host tool-not-found for an unknown, non-upstream name" do
      response = dispatcher.handle_request(request("tools/call", { "name" => "does_not_exist", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::METHOD_NOT_FOUND)
    end
  end

  describe "upstream error translation" do
    let(:proxy) { instance_double(McpToolkit::Gateway::Proxy) }

    before do
      McpToolkit.config.upstreams.register(key: upstream.key, url: upstream.url)
      allow(McpToolkit::Gateway::Proxy).to receive(:new).and_return(proxy)
    end

    it "relays an upstream JSON-RPC error verbatim (code + message + data)" do
      allow(proxy).to receive(:call).and_raise(
        McpToolkit::Gateway::UpstreamCallError.new("boom", jsonrpc_error: { "code" => -32_050, "message" => "nope", "data" => { "x" => 1 } })
      )

      response = dispatcher.handle_request(request("tools/call", { "name" => "notifications__send_email", "arguments" => {} }))

      expect(response[:error]).to eq(code: -32_050, message: "nope", data: { "x" => 1 })
    end

    it "maps a transport-level upstream failure (no jsonrpc_error) to internal_error" do
      allow(proxy).to receive(:call).and_raise(McpToolkit::Gateway::UpstreamCallError.new("timed out"))

      response = dispatcher.handle_request(request("tools/call", { "name" => "notifications__send_email", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INTERNAL_ERROR)
    end

    it "maps an unknown upstream to method-not-found" do
      allow(proxy).to receive(:call).and_raise(McpToolkit::Gateway::UnknownUpstream, "Unknown application: notifications")

      response = dispatcher.handle_request(request("tools/call", { "name" => "notifications__send_email", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::METHOD_NOT_FOUND)
    end
  end

  describe "upstream list_changed notification" do
    it "flushes the named upstream's cached aggregate" do
      McpToolkit.config.upstreams.register(key: upstream.key, url: upstream.url)
      aggregator = instance_double(McpToolkit::Gateway::Aggregator, flush!: nil)
      allow(McpToolkit::Gateway::Aggregator).to receive(:new).and_return(aggregator)

      # A notification (no id) returns nil from the dispatcher but must still flush.
      result = dispatcher.handle_request(request("notifications/notifications/tools/list_changed", {}, id: nil))

      expect(result).to be_nil
      expect(aggregator).to have_received(:flush!).with("notifications")
    end
  end
end
