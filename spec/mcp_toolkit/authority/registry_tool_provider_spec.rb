# frozen_string_literal: true

require "spec_helper"

# The authority-path counterpart to the satellite tools: the four GENERIC,
# Registry-backed tools (`resources` / `resource_schema` / `get` / `list`) served
# through McpToolkit::Authority::RegistryToolProvider over resources registered in
# `config.registry`, using a fake AR model + a fake serializer (no database). This
# proves the gem serves get/list/resources/resource_schema on the authority path
# by reusing the existing executors + schema builder UNCHANGED, and enforces the
# superuser / scope / account gates the design locked in.
RSpec.describe McpToolkit::Authority::RegistryToolProvider do
  subject(:provider) { described_class.new(config: McpToolkit.config) }

  let(:account) { FakeAccount.new(7) }
  let(:principal) { FakePrincipal.new(scopes:, superuser:) }
  let(:scopes) { [] }
  let(:superuser) { false }
  let(:context) { McpToolkit::Authority::Context.new(account:, principal:, bearer_token: "tok") }

  # A fake model exposing the column metadata resource_schema / ordering read.
  let(:widget_model) do
    Class.new do
      def self.columns_hash
        {
          "id" => FakeRelation::Column.new(:integer),
          "name" => FakeRelation::Column.new(:string),
          "booking_id" => FakeRelation::Column.new(:integer)
        }
      end
      def self.primary_key = "id"
      def self.model_name = FakeModelName.new("widgets")
    end
  end

  let(:widget_serializer) do
    model = widget_model
    Class.new(McpToolkit::Serializer::Base) do
      attributes :id, :name, :booking_id
      self.model_class = model
      def self.name = "WidgetSerializer"
    end
  end

  let(:rows) do
    [
      FakeRecord.new(id: 1, name: "alpha", booking_id: 10),
      FakeRecord.new(id: 2, name: "beta", booking_id: 20)
    ]
  end
  let(:relation) { FakeRelation.new(rows, table_name: "widgets", model: widget_model) }

  before do
    serializer = widget_serializer
    model = widget_model
    rel = relation
    McpToolkit.configure do |c|
      c.sql_sanitizer = FakeSqlSanitizer.new
      c.registry.register(:widgets) do
        model model
        serializer serializer
        description "Test widgets."
        filterable booking_id: :booking_id, name: :name
        scope { |_root| rel }
      end
    end
  end

  describe "#tool_definitions" do
    it "returns the four static generic tool definitions" do
      names = provider.tool_definitions(context).map { |definition| definition[:name] }

      expect(names).to contain_exactly("resources", "resource_schema", "get", "list")
    end

    it "gives every definition a name, description and inputSchema (the tools/list shape)" do
      provider.tool_definitions(context).each do |definition|
        expect(definition).to include(:name, :description, :inputSchema)
      end
    end

    it "is context-independent (superuser visibility is handled inside `resources`)" do
      su = McpToolkit::Authority::Context.new(account:, principal: FakePrincipal.new(superuser: true), bearer_token: "t")

      expect(provider.tool_definitions(su)).to eq(provider.tool_definitions(context))
    end
  end

  describe "#find" do
    it "resolves each known tool name to its tool instance" do
      expect(provider.find("get")).to be_a(McpToolkit::Authority::Tools::Get)
      expect(provider.find("list")).to be_a(McpToolkit::Authority::Tools::List)
      expect(provider.find("resources")).to be_a(McpToolkit::Authority::Tools::Resources)
      expect(provider.find("resource_schema")).to be_a(McpToolkit::Authority::Tools::ResourceSchema)
    end

    it "returns nil for an unknown tool name" do
      expect(provider.find("delete")).to be_nil
    end

    it "declares no STATIC scope (the per-resource scope is enforced at call time)" do
      expect(provider.find("list").required_permissions_scope).to be_nil
    end
  end

  describe "the `get` tool" do
    subject(:get) { provider.find("get") }

    it "fetches a single record by id, scoped through the account" do
      result = get.call(context:, resource: "widgets", id: 1)

      expect(result).to include(id: 1, name: "alpha")
    end

    it "honors a sparse fieldset" do
      result = get.call(context:, resource: "widgets", id: 1, fields: "id,name")

      expect(result).to eq(id: 1, name: "alpha")
    end

    it "maps a data-layer InvalidParams (unknown id) to the protocol InvalidParams (-32602)" do
      expect { get.call(context:, resource: "widgets", id: 999) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /not found/)
    end

    it "rejects an unknown resource with the protocol InvalidParams" do
      expect { get.call(context:, resource: "nope", id: 1) }
        .to raise_error(McpToolkit::Protocol::InvalidParams)
    end

    it "requires the resource argument" do
      expect { get.call(context:, resource: "", id: 1) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /resource is required/)
    end
  end

  describe "the `list` tool" do
    subject(:list) { provider.find("list") }

    it "returns the paginated collection wrapper scoped through the account" do
      result = list.call(context:, resource: "widgets")

      expect(result[:widgets].map { |widget| widget[:id] }).to eq([1, 2])
      expect(result[:meta]).to eq(total_count: 2, limit: 25, offset: 0)
    end

    it "applies a declared equality filter" do
      result = list.call(context:, resource: "widgets", filter: { booking_id: 10 })

      expect(result[:widgets].map { |widget| widget[:id] }).to eq([1])
    end

    it "rejects an unknown filter key with the protocol InvalidParams" do
      expect { list.call(context:, resource: "widgets", filter: { bogus: 1 }) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /unknown filter attribute/)
    end

    it "ignores a superuser account_id argument (it is resolved by the transport, not the tool)" do
      result = list.call(context:, resource: "widgets", account_id: 99)

      expect(result[:widgets].size).to eq(2)
    end
  end

  describe "the `resources` tool" do
    subject(:resources) { provider.find("resources") }

    it "lists every registered resource's name and description" do
      result = resources.call(context:)

      expect(result[:resources]).to contain_exactly({ name: "widgets", description: "Test widgets." })
    end
  end

  describe "the `resource_schema` tool" do
    subject(:resource_schema) { provider.find("resource_schema") }

    it "describes the resource shape without requiring a selected account" do
      accountless = McpToolkit::Authority::Context.new(account: nil, principal:, bearer_token: "t")

      schema = resource_schema.call(context: accountless, resource: "widgets")

      expect(schema[:name]).to eq("widgets")
      expect(schema[:attributes].map { |attribute| attribute[:name] }).to include(:booking_id)
    end
  end

  describe "superusers_only gating" do
    before do
      s = widget_serializer
      m = widget_model
      rel = relation
      McpToolkit.configure do |c|
        c.registry.register(:secrets) do
          superusers_only!
          model m
          serializer s
          description "Superuser-only."
          scope { |_root| rel }
        end
      end
    end

    context "for a non-superuser caller" do
      it "refuses `get`" do
        expect { provider.find("get").call(context:, resource: "secrets", id: 1) }
          .to raise_error(McpToolkit::Protocol::InvalidRequest, /superuser/)
      end

      it "refuses `list`" do
        expect { provider.find("list").call(context:, resource: "secrets") }
          .to raise_error(McpToolkit::Protocol::InvalidRequest, /superuser/)
      end

      it "refuses `resource_schema`" do
        expect { provider.find("resource_schema").call(context:, resource: "secrets") }
          .to raise_error(McpToolkit::Protocol::InvalidRequest, /superuser/)
      end

      it "HIDES the resource from `resources` discovery" do
        names = provider.find("resources").call(context:)[:resources].map { |resource| resource[:name] }

        expect(names).to eq(["widgets"])
      end
    end

    context "for a superuser caller" do
      let(:superuser) { true }

      it "allows `get`" do
        result = provider.find("get").call(context:, resource: "secrets", id: 1)

        expect(result).to include(id: 1)
      end

      it "reveals the resource in `resources` discovery" do
        names = provider.find("resources").call(context:)[:resources].map { |resource| resource[:name] }

        expect(names).to contain_exactly("widgets", "secrets")
      end
    end
  end

  describe "account requirement (get / list)" do
    let(:accountless) { McpToolkit::Authority::Context.new(account: nil, principal:, bearer_token: "t") }

    it "refuses `get` with InvalidParams when no account is resolved" do
      expect { provider.find("get").call(context: accountless, resource: "widgets", id: 1) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /account must be selected/)
    end

    it "refuses `list` with InvalidParams when no account is resolved" do
      expect { provider.find("list").call(context: accountless, resource: "widgets") }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /account must be selected/)
    end
  end

  describe "config.generic_tool_name_prefix" do
    context "when unset (the default empty prefix)" do
      it "advertises the four tools under their bare base names" do
        names = provider.tool_definitions(context).map { |definition| definition[:name] }

        expect(names).to contain_exactly("resources", "resource_schema", "get", "list")
      end

      it "resolves the bare base names" do
        expect(provider.find("list")).to be_a(McpToolkit::Authority::Tools::List)
      end
    end

    context "when set to a non-empty prefix" do
      before { McpToolkit.config.generic_tool_name_prefix = "foo_" }

      it "advertises the four tools under their prefixed names" do
        names = provider.tool_definitions(context).map { |definition| definition[:name] }

        expect(names).to contain_exactly("foo_resources", "foo_resource_schema", "foo_get", "foo_list")
      end

      it "resolves a prefixed name to its tool instance" do
        expect(provider.find("foo_list")).to be_a(McpToolkit::Authority::Tools::List)
        expect(provider.find("foo_resource_schema")).to be_a(McpToolkit::Authority::Tools::ResourceSchema)
      end

      it "no longer resolves the bare base name (only the prefixed name is a tool)" do
        expect(provider.find("list")).to be_nil
      end
    end
  end

  describe "per-resource scope gating" do
    before do
      s = widget_serializer
      m = widget_model
      rel = relation
      McpToolkit.configure do |c|
        c.registry.register(:scoped_widgets) do
          required_permissions_scope "widgets__read"
          model m
          serializer s
          description "Scoped widgets."
          scope { |_root| rel }
        end
      end
    end

    it "refuses a resource whose required scope the principal lacks" do
      expect { provider.find("list").call(context:, resource: "scoped_widgets") }
        .to raise_error(McpToolkit::Protocol::InvalidRequest, /widgets__read/)
    end

    context "when the principal carries the scope" do
      let(:scopes) { ["widgets__read"] }

      it "allows the call" do
        result = provider.find("list").call(context:, resource: "scoped_widgets")

        # The collection root key derives from the shared serializer's model name.
        expect(result[:widgets].size).to eq(2)
      end
    end
  end
end
