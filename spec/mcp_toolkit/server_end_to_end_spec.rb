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
      c.required_application = "widgets_app"
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
      body: JSON.generate(
        valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["widgets_app_read"]
      )
    )
  end

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
    response = call_tool({ "resource" => "widgets" })

    expect(response.dig("result", "isError")).to be_falsey
    text = response.dig("result", "content", 0, "text")
    payload = JSON.parse(text)
    expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
    expect(payload["meta"]).to include("total_count" => 2)
  end

  it "allows a list call when the token carries the required <app>_read scope" do
    # the default before-stub already carries scopes: ["widgets_app_read"]
    response = call_tool({ "resource" => "widgets" })

    expect(response.dig("result", "isError")).to be_falsey
    payload = JSON.parse(response.dig("result", "content", 0, "text"))
    expect(payload["widgets"].map { |w| w["id"] }).to eq([1, 2])
  end

  it "rejects a list call when the token lacks the required <app>_read scope" do
    stub_request(:post, introspect_endpoint).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: JSON.generate(
        # reaches the app (has a widgets_app_* scope) but not the read action
        valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["widgets_app_write"]
      )
    )

    response = call_tool({ "resource" => "widgets" })

    expect(response).not_to have_key("error") # protocol-level OK
    expect(response.dig("result", "isError")).to be(true)
    text = response.dig("result", "content", 0, "text")
    expect(text).to include("Unauthorized")
    expect(text).to include("widgets_app_read")
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
end
