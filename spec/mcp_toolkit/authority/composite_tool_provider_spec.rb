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

  describe "the composed default provider (config.tool_provider unset)" do
    # A bespoke tool CLASS exposing the contract SingleToolProvider wraps:
    # .definition / .tool_name plus the dispatcher's tool duck-type.
    let(:bespoke_tool_class) do
      Class.new do
        def self.tool_name = "audit_log"
        def self.definition = { name: "audit_log", description: "Audit.", inputSchema: { type: "object" } }
        def self.required_permissions_scope = nil
        def self.call(context:, **_args) = { entries: [] }
      end
    end

    it "stays nil for a pure gateway (no registered resources, no extras)" do
      expect(McpToolkit.config.tool_provider).to be_nil
    end

    it "defaults to the generic Registry-backed provider alone once resources are registered" do
      McpToolkit.registry.register(:things) { nil }

      expect(McpToolkit.config.tool_provider).to be_a(McpToolkit::Authority::RegistryToolProvider)
    end

    it "composes extra_tool_providers AFTER the registry provider, wrapping bare tool classes" do
      McpToolkit.registry.register(:things) { nil }
      McpToolkit.config.extra_tool_providers = [bespoke_tool_class]

      provider = McpToolkit.config.tool_provider
      names = provider.tool_definitions(context).map { |definition| definition[:name] }

      expect(names).to eq(%w[get list resource_schema resources audit_log])
      expect(provider.find("audit_log")).to eq(bespoke_tool_class)
      expect(provider.find("get")).to be_a(McpToolkit::Authority::Tools::Get)
    end

    it "accepts a ready-made provider in extra_tool_providers without wrapping it" do
      McpToolkit.config.extra_tool_providers = [bespoke_provider]

      expect(McpToolkit.config.tool_provider.find("paper_trail_versions")).to eq(bespoke_tool)
    end

    it "serves ONLY the extras when the registry is empty (no phantom generic tools)" do
      McpToolkit.config.extra_tool_providers = [bespoke_tool_class]

      names = McpToolkit.config.tool_provider.tool_definitions(context).map { |definition| definition[:name] }

      expect(names).to eq(%w[audit_log])
    end

    it "yields entirely to an explicitly assigned tool_provider" do
      McpToolkit.config.tool_provider = bespoke_provider
      McpToolkit.config.extra_tool_providers = [bespoke_tool_class]

      expect(McpToolkit.config.tool_provider).to eq(bespoke_provider)
    end
  end

  describe "exported serializer adapter structs" do
    it "satisfy the association duck-type the schema builder probes" do
      descriptor = McpToolkit::Serializer::AssociationDescriptor.new(
        name: :booking, type: :has_one, polymorphic: false, links_key: "booking",
        serializer: McpToolkit::Serializer::TargetRef.new(Object)
      )

      expect(descriptor.links_key).to eq("booking")
      expect(descriptor.serializer.model_class).to eq(Object)
    end
  end
end
