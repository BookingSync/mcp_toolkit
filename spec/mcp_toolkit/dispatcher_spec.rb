# frozen_string_literal: true

require "spec_helper"

# The hand-rolled authority dispatcher: request validation, method dispatch,
# version negotiation, host tool serving + scope gate, and the JSON-RPC error
# envelope. Gateway routing lives in dispatcher_gateway_spec. Ported from core's
# server_spec, rebased on the injected context + tool_provider.
RSpec.describe McpToolkit::Dispatcher do
  subject(:dispatcher) { described_class.new(context:, config: McpToolkit.config) }

  let(:account) { FakeAccount.new(42) }
  let(:principal) { FakePrincipal.new(scopes:) }
  let(:scopes) { [] }
  let(:context) { McpToolkit::Authority::Context.new(account:, principal:, bearer_token: "tok") }

  let(:echo_tool) { FakeTool.new { |ctx, args| { echoed: args, account_id: ctx.account&.id } } }
  let(:provider) { FakeToolProvider.new(tools: { "echo" => echo_tool }) }

  before { McpToolkit.config.tool_provider = provider }

  def request(method, params = {}, id: 1)
    body = { "jsonrpc" => "2.0", "method" => method, "params" => params }
    id.nil? ? body : body.merge("id" => id)
  end

  describe "request validation" do
    it "rejects a request missing the jsonrpc version" do
      response = dispatcher.handle_request({ "method" => "ping", "id" => 1 })

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_REQUEST)
      expect(response[:error][:message]).to include("Missing jsonrpc version")
    end

    it "rejects a request with the wrong jsonrpc version" do
      response = dispatcher.handle_request({ "jsonrpc" => "1.0", "method" => "ping", "id" => 1 })

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_REQUEST)
    end

    it "rejects a request without a method" do
      response = dispatcher.handle_request({ "jsonrpc" => "2.0", "id" => 1 })

      expect(response[:error][:message]).to include("Missing method")
    end
  end

  describe "initialize" do
    it "echoes the requested protocol version when supported, else the latest" do
      supported = dispatcher.handle_request(request("initialize", { "protocolVersion" => "2025-03-26" }))
      unsupported = dispatcher.handle_request(request("initialize", { "protocolVersion" => "1999-01-01" }))

      expect(supported[:result][:protocolVersion]).to eq("2025-03-26")
      expect(unsupported[:result][:protocolVersion]).to eq(McpToolkit::Protocol::LATEST_VERSION)
    end

    it "negotiates against config.supported_protocol_versions when the host narrows the set" do
      McpToolkit.config.supported_protocol_versions = %w[2025-06-18]

      response = dispatcher.handle_request(request("initialize", { "protocolVersion" => "2025-03-26" }))

      expect(response[:result][:protocolVersion]).to eq("2025-06-18")
    end

    it "returns the configured server identity and listChanged capability" do
      McpToolkit.config.server_name = "acme-mcp"
      McpToolkit.config.server_version = "3.1.4"

      response = dispatcher.handle_request(request("initialize"))

      expect(response[:result][:serverInfo]).to eq(name: "acme-mcp", version: "3.1.4")
      expect(response[:result][:capabilities][:tools]).to eq(listChanged: true)
    end
  end

  describe "notifications (no id)" do
    it "recognizes notifications/initialized and returns no response" do
      expect(dispatcher.handle_request(request("notifications/initialized", {}, id: nil))).to be_nil
    end
  end

  describe "ping" do
    it "returns an empty result" do
      expect(dispatcher.handle_request(request("ping"))[:result]).to eq({})
    end
  end

  describe "tools/list" do
    it "exposes the host provider's tool definitions" do
      names = dispatcher.handle_request(request("tools/list"))[:result][:tools].pluck(:name)

      expect(names).to eq(["echo"])
    end

    it "contributes nothing when no tool_provider is configured (a pure gateway)" do
      McpToolkit.config.tool_provider = nil

      expect(dispatcher.handle_request(request("tools/list"))[:result][:tools]).to eq([])
    end
  end

  describe "tools/call" do
    it "runs the host tool and wraps a Hash result as JSON text content" do
      response = dispatcher.handle_request(
        request("tools/call", { "name" => "echo", "arguments" => { "q" => "hi" } })
      )
      content = JSON.parse(response[:result][:content].first[:text])

      expect(content).to eq("echoed" => { "q" => "hi" }, "account_id" => 42)
    end

    it "passes the request context and deep-symbolized arguments to the tool" do
      dispatcher.handle_request(
        request("tools/call", { "name" => "echo", "arguments" => { "nested" => { "a" => 1 } } })
      )

      call = echo_tool.calls.first
      expect(call[:arguments]).to eq(nested: { a: 1 })
      expect(call[:context]).to be(context)
    end

    it "wraps a String result as text content verbatim" do
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "echo" => FakeTool.new(result: "plain text") })

      response = dispatcher.handle_request(request("tools/call", { "name" => "echo", "arguments" => {} }))

      expect(response[:result][:content]).to eq([{ type: "text", text: "plain text" }])
    end

    it "returns method-not-found for an unknown tool" do
      response = dispatcher.handle_request(request("tools/call", { "name" => "nope", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::METHOD_NOT_FOUND)
      expect(response[:error][:message]).to include("Tool not found")
    end

    it "maps an unexpected tool error to internal_error" do
      exploding = FakeTool.new { |_ctx, _args| raise "boom" }
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "echo" => exploding })

      response = dispatcher.handle_request(request("tools/call", { "name" => "echo", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INTERNAL_ERROR)
    end
  end

  describe "per-tool scope enforcement (centralized in the dispatcher)" do
    let(:scoped_tool) { FakeTool.new(scope: "acme__read", result: { ok: true }) }
    let(:provider) { FakeToolProvider.new(tools: { "echo" => scoped_tool }) }

    it "refuses a call when the principal lacks the tool's required scope" do
      response = dispatcher.handle_request(request("tools/call", { "name" => "echo", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_REQUEST)
      expect(response[:error][:message]).to include("acme__read")
      expect(scoped_tool.calls).to be_empty
    end

    context "when the principal carries the required scope" do
      let(:scopes) { ["acme__read"] }

      it "passes the gate and runs the tool" do
        response = dispatcher.handle_request(request("tools/call", { "name" => "echo", "arguments" => {} }))

        expect(response).to have_key(:result)
        expect(scoped_tool.calls.size).to eq(1)
      end
    end
  end

  describe "unknown method" do
    it "returns method-not-found" do
      response = dispatcher.handle_request(request("frobnicate"))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::METHOD_NOT_FOUND)
      expect(response[:error][:message]).to include("Method not found: frobnicate")
    end
  end
end
