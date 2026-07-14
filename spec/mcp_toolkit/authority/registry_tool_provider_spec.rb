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
    it "returns the four generic tool definitions in the pre-gem (alphabetical) order" do
      names = provider.tool_definitions(context).map { |definition| definition[:name] }

      expect(names).to eq(%w[get list resource_schema resources])
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

    it "rejects arguments outside the input schema instead of silently ignoring them (pre-gem parity)" do
      expect { get.call(context:, resource: "widgets", id: 1, bogus: true) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /unknown argument\(s\): bogus/)
    end

    it "tolerates the transport-level account_id selector" do
      result = get.call(context:, resource: "widgets", id: 1, account_id: 99)

      expect(result).to include(id: 1)
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

    it "lists every registered resource's name, description and filterability" do
      result = resources.call(context:)

      expect(result[:resources]).to contain_exactly(
        { name: "widgets", description: "Test widgets.", filterable: true }
      )
    end

    it "tolerates ANY extra argument (unlike get/resource_schema — pre-gem parity)" do
      result = resources.call(context:, bogus: 1, account_id: 99)

      expect(result[:resources]).not_to be_empty
    end

    context "with an unfilterable resource carrying a usage note" do
      before do
        s = widget_serializer
        m = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:raw_events) do
            model m
            serializer s
            description "Raw events."
            note "Internal debugging data; do not interpret without domain knowledge."
            scope { |_root| rel }
          end
        end
      end

      it "surfaces filterable: false and the note at browse time" do
        result = resources.call(context:)

        expect(result[:resources]).to include(
          name: "raw_events",
          description: "Raw events.",
          filterable: false,
          note: "Internal debugging data; do not interpret without domain knowledge."
        )
      end
    end

    context "with a resource whose lazy filterable source raises" do
      before do
        s = widget_serializer
        m = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:flaky) do
            model m
            serializer s
            description "Flaky."
            filterable { raise "boom: db unavailable" }
            scope { |_root| rel }
          end
        end
      end

      it "keeps the whole discovery index available, omitting only that resource's filterable key" do
        result = resources.call(context:)
        flaky_entry = result[:resources].find { |resource| resource[:name] == "flaky" }
        widgets_entry = result[:resources].find { |resource| resource[:name] == "widgets" }

        expect(flaky_entry).to eq(name: "flaky", description: "Flaky.")
        expect(widgets_entry).to include(filterable: true)
      end
    end

    context "with a resource whose only filter is a custom filter" do
      before do
        s = widget_serializer
        m = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:custom_only) do
            model m
            serializer s
            description "Custom-filter-only."
            filter :for_booking, type: :integer, description: "Only rows for this booking" do |relation, value|
              relation.where(booking_id: value)
            end
            scope { |_root| rel }
          end
        end
      end

      it "counts the custom filter as filterable" do
        result = resources.call(context:)
        entry = result[:resources].find { |resource| resource[:name] == "custom_only" }

        expect(entry).to include(filterable: true)
      end
    end
  end

  describe "the advertised filter grammar (discoverability contract)" do
    it "documents the operator payload shape, NULL token, IN sets and resource_filters in the `list` description" do
      description = provider.tool_definitions(context).find { |d| d[:name] == "list" }[:description]

      expect(description).to include('{ "op": <operator>, "value": <value> }')
        .and include('"gteq"')
        .and include('"null"')
        .and include("array of scalars")
        .and include("resource_filters")
    end

    it "embeds the exact tokenized grammar bullet (the substitution anchor for :literal hosts)" do
      list_class = McpToolkit::Authority::Tools::List

      expect(list_class.description).to include(list_class::BARE_VALUE_GRAMMAR[:tokenized])
    end

    context "when the host configures :literal bare-value semantics" do
      before { McpToolkit.config.bare_filter_value_semantics = :literal }

      # Served docs must describe the semantics the host actually configured —
      # a client following tokenization advice on a :literal host would send
      # comma/"null" filters that silently match nothing.
      it "serves the literal bare-value grammar in the `list` description" do
        description = provider.tool_definitions(context).find { |d| d[:name] == "list" }[:description]

        expect(description).to include("LITERALLY")
        expect(description).not_to include('"booked,canceled"')
      end
    end

    it "documents resource_filters and the filterable/note keys in the discovery tools' descriptions" do
      definitions = provider.tool_definitions(context)
      schema_description = definitions.find { |d| d[:name] == "resource_schema" }[:description]
      resources_description = definitions.find { |d| d[:name] == "resources" }[:description]

      expect(schema_description).to include("resource_filters").and include("TOP-LEVEL")
      expect(resources_description).to include("`filterable`").and include("`note`")
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

    it "rejects arguments outside the input schema (pre-gem parity)" do
      expect { resource_schema.call(context:, resource: "widgets", bogus: 1) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /unknown argument\(s\): bogus/)
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

      # Prose pointing at `resources` on a server that only advertises
      # `foo_resources` would send a client to a tool that does not exist.
      it "rewrites sibling-tool references in every description to the prefixed names" do
        provider.tool_definitions(context).each do |definition|
          expect(definition[:description]).not_to match(/`(resources|resource_schema|get|list)`/)
        end
      end

      it "rewrites every tool's cross-references, not just one tool's" do
        by_name = provider.tool_definitions(context).to_h { |d| [d[:name], d[:description]] }

        expect(by_name["foo_list"]).to include("`foo_resources`").and include("`foo_resource_schema`")
        expect(by_name["foo_get"]).to include("`foo_resources`")
        expect(by_name["foo_resources"]).to include("`foo_resource_schema`")
        expect(by_name["foo_resource_schema"]).to include("`foo_resources`").and include("`foo_list`")
      end

      it "rewrites sibling-tool references inside input schema property descriptions" do
        list_definition = provider.tool_definitions(context).find { |d| d[:name] == "foo_list" }
        resource_property = list_definition[:inputSchema][:properties][:resource]

        expect(resource_property[:description]).to include("`foo_resources`")
      end

      it "preserves every non-prose input schema value through the rewrite walk" do
        list_schema = provider.tool_definitions(context).find { |d| d[:name] == "foo_list" }[:inputSchema]

        expect(list_schema[:required]).to eq(["resource"])
        expect(list_schema[:properties][:fields][:type]).to eq(%w[array string])
        expect(list_schema[:properties][:filter][:additionalProperties]).to be(true)
        # Top-level custom (resource-specific) filters arrive as extra arguments.
        expect(list_schema[:additionalProperties]).to be(true)
        expect(list_schema[:type]).to eq("object")
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
