# frozen_string_literal: true

require "spec_helper"

# End-to-end through the wrapped official MCP::Server: a JSON-RPC `tools/call` for
# the generic `list` tool, exercising server -> Tools::Base -> Authenticator ->
# Introspection (stubbed central) -> ListExecutor -> serializer -> the MCP tool
# response envelope.
RSpec.describe "Server end-to-end (tools/call)" do
  let(:central_url) { "https://central.example.com" }
  let(:introspect_endpoint) { "#{central_url}/mcp/tokens/introspect" }

  let(:widget_serializer) do
    model = widget_model
    Class.new(McpToolkit::Serializer::Base) do
      attributes :id, :name
      self.model_class = model

      def self.name
        "WidgetEndToEndSerializer"
      end
    end
  end

  let(:widget_model) do
    Class.new do
      def self.model_name
        FakeModelName.new("widgets")
      end
    end
  end

  let(:rows) { [FakeRecord.new(id: 1, name: "alpha"), FakeRecord.new(id: 2, name: "beta")] }

  before do
    serializer = widget_serializer
    model = widget_model
    relation = FakeRelation.new(rows, table_name: "widgets")

    McpToolkit.configure do |c|
      c.server_name = "e2e-mcp"
      c.central_app_url = central_url
      c.account_resolver = ->(synced_id) { synced_id == 42 ? :account_42 : nil }
      # The registry default scope applies to every resource that doesn't declare
      # its own (and to the discovery tools).
      c.registry.default_required_permissions_scope "widgets_app__read"
      c.registry.register(:widgets) do
        model model
        serializer serializer
        description "Widgets."
        scope { |_root| relation }
      end
    end

    stub_request(:post, introspect_endpoint).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: JSON.generate(
        valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["widgets_app__read"]
      )
    )
  end

  # The canonical happy-path call: a `list` for the widgets resource with the
  # default before-stub (token carries `widgets_app__read`).
  subject(:list_response) { call_tool({ "resource" => "widgets" }) }

  def call_tool(arguments, bearer: "forwarded-token")
    server = McpToolkit::Server.build(server_context: { bearer_token: bearer, header_account_id: nil })
    request = {
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "list", arguments: }
    }
    JSON.parse(server.handle_json(JSON.generate(request)))
  end

  it "returns the serialized collection as a text tool result" do
    expect(list_response.dig("result", "isError")).to be_falsey
    text = list_response.dig("result", "content", 0, "text")
    payload = JSON.parse(text)
    expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
    expect(payload["meta"]).to include("total_count" => 2)
  end

  it "allows a list call when the token carries the required <app>__read scope" do
    # the default before-stub already carries scopes: ["widgets_app__read"]
    expect(list_response.dig("result", "isError")).to be_falsey
    payload = JSON.parse(list_response.dig("result", "content", 0, "text"))
    expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
  end

  it "rejects a list call when the token lacks the required <app>__read scope" do
    stub_request(:post, introspect_endpoint).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: JSON.generate(
        # reaches the app (has a widgets_app_* scope) but not the read action
        valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["widgets_app__write"]
      )
    )

    response = call_tool({ "resource" => "widgets" })

    expect(response).not_to have_key("error") # protocol-level OK
    expect(response.dig("result", "isError")).to be(true)
    text = response.dig("result", "content", 0, "text")
    expect(text).to include("Unauthorized")
    expect(text).to include("widgets_app__read")
  end

  it "surfaces an unknown resource as an isError tool result, not a protocol error" do
    response = call_tool({ "resource" => "nonexistent" })

    expect(response).not_to have_key("error") # protocol-level OK
    expect(response.dig("result", "isError")).to be(true)
    expect(response.dig("result", "content", 0, "text")).to match(/unknown resource/i)
  end

  it "surfaces an invalid token as an Unauthorized isError result" do
    stub_request(:post, introspect_endpoint).to_return(status: 401, body: JSON.generate(valid: false))

    response = call_tool({ "resource" => "widgets" })

    expect(response.dig("result", "isError")).to be(true)
    expect(response.dig("result", "content", 0, "text")).to include("Unauthorized")
  end

  it "lists the four generic tools" do
    server = McpToolkit::Server.build(server_context: { bearer_token: "x" })
    response = JSON.parse(server.handle_json(JSON.generate(jsonrpc: "2.0", id: 9, method: "tools/list", params: {})))

    names = response.dig("result", "tools").map { |t| t["name"] }
    expect(names).to contain_exactly("get", "list", "resources", "resource_schema")
  end

  describe "explicit per-resource required_permissions_scope" do
    # A second resource declaring its OWN scope, overriding the registry default,
    # registered alongside the default-scoped `widgets`.
    before do
      serializer = widget_serializer
      model = widget_model
      relation = FakeRelation.new(rows, table_name: "gadgets")
      McpToolkit.registry.register(:gadgets) do
        model model
        serializer serializer
        description "Gadgets."
        required_permissions_scope "gadgets_app__read"
        scope { |_root| relation }
      end
    end

    def stub_scopes(scopes)
      stub_request(:post, introspect_endpoint).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: JSON.generate(
          valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes:
        )
      )
    end

    it "rejects a resource-scoped tool when the token lacks the resource's own scope" do
      stub_scopes(["widgets_app__read"]) # has the default, not the gadgets scope

      response = call_tool({ "resource" => "gadgets" })

      expect(response).not_to have_key("error")
      expect(response.dig("result", "isError")).to be(true)
      text = response.dig("result", "content", 0, "text")
      expect(text).to include("Unauthorized")
      expect(text).to include("gadgets_app__read")
    end

    it "accepts a resource-scoped tool when the token carries the resource's own scope" do
      stub_scopes(["gadgets_app__read"])

      response = call_tool({ "resource" => "gadgets" })

      expect(response.dig("result", "isError")).to be_falsey
      # The collection root key derives from the (shared) serializer's model name,
      # "widgets"; the assertion that matters here is that the call was authorized.
      payload = JSON.parse(response.dig("result", "content", 0, "text"))
      expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
    end
  end

  describe "the registry default scope" do
    it "applies to a resource that declares no scope of its own" do
      # `widgets` declares no scope; the registry default `widgets_app__read` is
      # what the default before-stub carries, so the call is allowed.
      expect(list_response.dig("result", "isError")).to be_falsey
    end
  end

  describe "a resource (and discovery) with NO scope required at all" do
    # A registry with neither a default scope nor a per-resource scope: any valid
    # token reaches the tools.
    before do
      serializer = widget_serializer
      model = widget_model
      relation = FakeRelation.new(rows, table_name: "widgets")
      # Start from a pristine config (the outer before set a registry default
      # scope; this scenario needs none).
      McpToolkit.reset_config!
      McpToolkit.configure do |c|
        c.server_name = "open-mcp"
        c.central_app_url = central_url
        c.account_resolver = ->(synced_id) { synced_id == 42 ? :account_42 : nil }
        c.registry.register(:widgets) do
          model model
          serializer serializer
          description "Widgets."
          scope { |_root| relation }
        end
      end

      stub_request(:post, introspect_endpoint).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        # token carries NO scopes at all
        body: JSON.generate(valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: [])
      )
    end

    it "is reachable by any valid token (list)" do
      response = call_tool({ "resource" => "widgets" })

      expect(response.dig("result", "isError")).to be_falsey
      payload = JSON.parse(response.dig("result", "content", 0, "text"))
      expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
    end

    it "is reachable by any valid token (discovery: resources)" do
      server = McpToolkit::Server.build(server_context: { bearer_token: "forwarded-token", header_account_id: nil })
      request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "resources", arguments: {} } }
      response = JSON.parse(server.handle_json(JSON.generate(request)))

      expect(response.dig("result", "isError")).to be_falsey
    end
  end
end
