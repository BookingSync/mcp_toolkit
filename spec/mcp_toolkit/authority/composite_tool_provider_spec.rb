# frozen_string_literal: true

require "spec_helper"

# Composing the generic Registry-backed provider with a host's bespoke tools
# behind a single `config.tool_provider`, so both are served by the one
# dispatcher. Uses the reusable FakeToolProvider double for the bespoke side.
RSpec.describe McpToolkit::Authority::CompositeToolProvider do
  let(:registry_provider) { McpToolkit::Authority::RegistryToolProvider.new(config: McpToolkit.config) }
  let(:bespoke_tool) { FakeTool.new { |_ctx, _args| { versions: [] } } }
  let(:bespoke_provider) { FakeToolProvider.new(tools: { "paper_trail_versions" => bespoke_tool }) }
  let(:context) { McpToolkit::Authority::Context.new(account: FakeAccount.new(1), principal: FakePrincipal.new) }

  subject(:composite) { described_class.new(registry_provider, bespoke_provider) }

  describe "#tool_definitions" do
    it "concatenates every provider's definitions in registration order" do
      names = composite.tool_definitions(context).map { |definition| definition[:name] }

      expect(names).to eq(%w[get list resource_schema resources paper_trail_versions])
    end
  end

  describe "#find" do
    it "resolves a name owned by the first provider" do
      expect(composite.find("get")).to be_a(McpToolkit::Authority::Tools::Get)
    end

    it "falls through to a later provider for a name it owns" do
      expect(composite.find("paper_trail_versions")).to eq(bespoke_tool)
    end

    it "returns nil when no provider resolves the name" do
      expect(composite.find("nope")).to be_nil
    end

    it "prefers the first provider that resolves a shared name" do
      shadow = FakeToolProvider.new(tools: { "get" => FakeTool.new })
      first_wins = described_class.new(registry_provider, shadow)

      expect(first_wins.find("get")).to be_a(McpToolkit::Authority::Tools::Get)
    end
  end
end
