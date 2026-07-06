# frozen_string_literal: true

require "spec_helper"

# The api-agnostic seam (Req 1): the gem serves a host's own tools ONLY through the
# injected `config.tool_provider`, and enforces the per-tool scope gate CENTRALLY
# (in the dispatcher) rather than trusting each tool. This exercises the full
# contract through the dispatcher (the gem's real caller) with a provider + tools
# that have ZERO app/api knowledge, proving the gem never needs to.
RSpec.describe "tool_provider contract" do
  subject(:dispatcher) { McpToolkit::Dispatcher.new(context:, config: McpToolkit.config) }

  let(:account) { FakeAccount.new(7) }
  let(:principal) { FakePrincipal.new(scopes:, superuser:) }
  let(:scopes) { [] }
  let(:superuser) { false }
  let(:context) { McpToolkit::Authority::Context.new(account:, principal:, bearer_token: "tok") }

  def request(method, params = {})
    { "jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params }
  end

  describe "provider.tool_definitions(context)" do
    let(:provider) do
      FakeToolProvider.new do |ctx|
        base = [{ name: "widgets_list", description: "List widgets", inputSchema: { type: "object" } }]
        # The context lets the host hide a superuser-only tool from other callers.
        ctx.superuser? ? base + [{ name: "audit_dump", description: "Dump", inputSchema: { type: "object" } }] : base
      end
    end

    before { McpToolkit.config.tool_provider = provider }

    it "is passed the request context so the provider can hide superuser-only tools" do
      names = dispatcher.handle_request(request("tools/list"))[:result][:tools].pluck(:name)

      expect(names).to eq(["widgets_list"])
    end

    context "when the principal is a superuser" do
      let(:superuser) { true }

      it "reveals the superuser-only tool" do
        names = dispatcher.handle_request(request("tools/list"))[:result][:tools].pluck(:name)

        expect(names).to contain_exactly("widgets_list", "audit_dump")
      end
    end
  end

  describe "provider.find(name) + tool.call(context:, **arguments)" do
    let(:tool) { FakeTool.new { |ctx, args| { seen_account: ctx.account.id, args: } } }

    before { McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "widgets_list" => tool }) }

    it "resolves the tool by name and invokes it with the context + arguments" do
      response = dispatcher.handle_request(
        request("tools/call", { "name" => "widgets_list", "arguments" => { "limit" => 5 } })
      )
      content = JSON.parse(response[:result][:content].first[:text])

      expect(content).to eq("seen_account" => 7, "args" => { "limit" => 5 })
    end
  end

  describe "central scope enforcement (the gem gates, not the tool)" do
    let(:tool) { FakeTool.new(scope: "widgets_app__read") { |_ctx, _args| { ok: true } } }

    before { McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "widgets_list" => tool }) }

    it "refuses a scoped tool for a principal without the scope, WITHOUT invoking it" do
      response = dispatcher.handle_request(request("tools/call", { "name" => "widgets_list", "arguments" => {} }))

      expect(response[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_REQUEST)
      expect(tool.calls).to be_empty
    end

    context "with the scope granted" do
      let(:scopes) { ["widgets_app__read"] }

      it "invokes the tool" do
        response = dispatcher.handle_request(request("tools/call", { "name" => "widgets_list", "arguments" => {} }))

        expect(response).to have_key(:result)
        expect(tool.calls.size).to eq(1)
      end
    end
  end

  describe "the gem carries no host/api-layer coupling" do
    it "has no api_v3 / serializer / catalog references in the authority + dispatch code" do
      root = File.expand_path("../../lib/mcp_toolkit", __dir__)
      sources = Dir[File.join(root, "{dispatcher,protocol}.rb"), File.join(root, "authority", "**", "*.rb"),
                    File.join(root, "authority.rb"), File.join(root, "tools", "authority_base.rb")]
      blob = sources.map { |f| File.read(f) }.join("\n").downcase

      expect(blob).not_to match(/api_v3|api::v3/)
    end
  end
end
