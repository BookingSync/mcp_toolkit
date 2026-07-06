# frozen_string_literal: true

require "spec_helper"

# McpToolkit::Tools::AuthorityBase — the optional base a host tool subclasses. It
# satisfies the dispatcher's duck-typed tool contract as CLASS methods
# (`.required_permissions_scope` + `.call(context:, **arguments)`), exposes the
# context accessors, gates superuser-only resources, and maps tool errors to
# protocol errors.
RSpec.describe McpToolkit::Tools::AuthorityBase do
  let(:account) { FakeAccount.new(99) }
  let(:principal) { FakePrincipal.new(superuser:) }
  let(:superuser) { false }
  let(:context) { McpToolkit::Authority::Context.new(account:, principal:, bearer_token: "tok") }

  let(:tool_class) do
    Class.new(described_class) do
      tool_name "widget_get"
      description "Fetch a widget."
      required_permissions_scope "widgets__read"
      input_schema { { type: "object", properties: { id: { type: "string" } }, required: ["id"] } }

      def call(id:)
        { id:, account_id: account.id, principal_present: !principal.nil?, bearer: bearer_token }
      end
    end
  end

  describe "the class-level tool contract" do
    it "exposes required_permissions_scope for the dispatcher's gate" do
      expect(tool_class.required_permissions_scope).to eq("widgets__read")
    end

    it "builds a tool definition mirroring the tools/list shape" do
      expect(tool_class.definition).to eq(
        name: "widget_get",
        description: "Fetch a widget.",
        inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] }
      )
    end

    it "does NOT inherit a scope declared on an ancestor" do
      subclass = Class.new(tool_class) { tool_name "sub" }

      expect(subclass.required_permissions_scope).to be_nil
    end

    it "defaults tool_name to the demodulized/underscored class name" do
      stub_const("Acme::FooBarTool", Class.new(described_class))

      expect(Acme::FooBarTool.tool_name).to eq("foo_bar")
    end
  end

  describe ".call(context:, **arguments)" do
    it "runs the business logic with the context accessors bound" do
      result = tool_class.call(context:, id: "w1")

      expect(result).to eq(id: "w1", account_id: 99, principal_present: true, bearer: "tok")
    end

    it "maps a missing required keyword (ArgumentError) to InvalidParams" do
      expect { tool_class.call(context:) }
        .to raise_error(McpToolkit::Protocol::InvalidParams)
    end

    it "maps an unexpected StandardError to InternalError" do
      exploding = Class.new(described_class) { def call(**) = raise("kaboom") }

      expect { exploding.call(context:) }.to raise_error(McpToolkit::Protocol::InternalError, /kaboom/)
    end

    it "lets a deliberately-raised protocol error pass through with its own code" do
      raising = Class.new(described_class) do
        def call(**)
          raise McpToolkit::Protocol::InvalidParams.new("id is required")
        end
      end

      expect { raising.call(context:) }.to raise_error(McpToolkit::Protocol::InvalidParams, /id is required/)
    end
  end

  describe "#ensure_resource_accessible!" do
    let(:restricted) { double("resource", superusers_only?: true, name: "AuditLog") }
    let(:open_resource) { double("resource", superusers_only?: false, name: "Widget") }

    let(:gating_tool) do
      Class.new(described_class) do
        def call(resource:)
          ensure_resource_accessible!(resource)
          { ok: true }
        end
      end
    end

    it "refuses a superuser-only resource for a non-superuser caller" do
      expect { gating_tool.call(context:, resource: restricted) }
        .to raise_error(McpToolkit::Protocol::InvalidRequest, /restricted to superuser/)
    end

    it "allows an unrestricted resource for any caller" do
      expect(gating_tool.call(context:, resource: open_resource)).to eq(ok: true)
    end

    context "with a superuser caller" do
      let(:superuser) { true }

      it "allows the superuser-only resource" do
        expect(gating_tool.call(context:, resource: restricted)).to eq(ok: true)
      end
    end
  end

  describe "end-to-end through the dispatcher" do
    let(:principal) { FakePrincipal.new(scopes: ["widgets__read"]) }

    it "plugs into the provider seam and is served + scope-gated by the dispatcher" do
      klass = tool_class
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "widget_get" => klass })

      response = McpToolkit::Dispatcher.new(context:, config: McpToolkit.config).handle_request(
        { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call",
          "params" => { "name" => "widget_get", "arguments" => { "id" => "w9" } } }
      )
      content = JSON.parse(response[:result][:content].first[:text])

      expect(content["id"]).to eq("w9")
      expect(content["account_id"]).to eq(99)
    end
  end
end
