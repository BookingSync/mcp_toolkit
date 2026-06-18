# frozen_string_literal: true

require "spec_helper"

# Exercises the core data path: a registered resource -> List/Get executors ->
# the resource's serializer, including filterable-attribute validation and the
# tenancy scope block. Uses the in-memory fakes (no database).
RSpec.describe "Registry + executors + serializer (data path)" do
  # A serializer for the fake "widget" model. Subclasses the gem's base, but
  # overrides model_class / root_key so we don't need a real constant.
  let(:widget_serializer) do
    model = widget_model
    Class.new(McpToolkit::Serializer::Base) do
      attributes :id, :name, :booking_id
      self.model_class = model

      def self.name
        "WidgetSerializer"
      end
    end
  end

  # A fake model exposing the column metadata resource_schema reads.
  let(:widget_model) do
    Class.new do
      def self.columns_hash
        {
          "id" => FakeRelation::Column.new(:integer),
          "name" => FakeRelation::Column.new(:string),
          "booking_id" => FakeRelation::Column.new(:integer)
        }
      end

      def self.model_name
        FakeModelName.new("widgets")
      end
    end
  end

  let(:account) { :account_root }

  let(:rows) do
    [
      FakeRecord.new(id: 1, name: "alpha", booking_id: 10),
      FakeRecord.new(id: 2, name: "beta", booking_id: 20),
      FakeRecord.new(id: 3, name: "gamma", booking_id: 10)
    ]
  end

  let(:relation) { FakeRelation.new(rows, table_name: "widgets") }
  let(:resource) { McpToolkit.registry.fetch("widgets") }

  before do
    serializer = widget_serializer
    model = widget_model
    rel = relation
    McpToolkit.configure do |c|
      c.registry.register(:widgets) do
        model model
        serializer serializer
        description "Test widgets."
        filterable booking_id: :booking_id
        scope { |_root| rel }
      end
    end
  end

  describe McpToolkit::ListExecutor do
    it "returns the collection wrapper keyed by the plural root with pagination meta" do
      result = described_class.call(resource:, scope_root: account, params: {})

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2, 3])
      # ListExecutor passes its effective (defaulted) limit/offset into the meta.
      expect(result[:meta]).to eq(total_count: 3, limit: 25, offset: 0)
      expect(result[:widgets].first).to include(name: "alpha", "links" => {})
    end

    it "applies declared per-attribute equality filters by mapping request key -> column" do
      result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: 10 } })

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 3])
    end

    it "rejects unknown filter keys with InvalidParams" do
      expect do
        described_class.call(resource:, scope_root: account, params: { filter: { bogus: 1 } })
      end.to raise_error(McpToolkit::Errors::InvalidParams, /unknown filter attribute/)
    end

    it "filters by ids" do
      result = described_class.call(resource:, scope_root: account, params: { ids: "1,3" })

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 3])
    end
  end

  describe McpToolkit::GetExecutor do
    it "fetches a single record by id, scoped through the relation" do
      result = described_class.call(resource:, scope_root: account, id: 2)

      expect(result).to include(id: 2, name: "beta")
    end

    it "raises InvalidParams when the id is missing from the scoped relation" do
      expect do
        described_class.call(resource:, scope_root: account, id: 999)
      end.to raise_error(McpToolkit::Errors::InvalidParams, /not found/)
    end

    it "requires an id" do
      expect do
        described_class.call(resource:, scope_root: account, id: nil)
      end.to raise_error(McpToolkit::Errors::InvalidParams, /id is required/)
    end
  end

  describe McpToolkit::ResourceSchema do
    it "describes attributes (with column types) and the declared filters" do
      schema = described_class.call(resource)

      expect(schema[:name]).to eq("widgets")
      expect(schema[:description]).to eq("Test widgets.")
      booking = schema[:attributes].find { |a| a[:name] == :booking_id }
      expect(booking).to include(type: "integer", filterable: true)
      expect(schema[:standard_filters]).to eq(%w[ids updated_since limit offset])
      expect(schema[:filters]).to eq([{ key: :booking_id, column: :booking_id, type: "integer", format: "integer" }])
    end
  end

  describe McpToolkit::Registry do
    it "raises UnknownResource for an unregistered name" do
      expect { McpToolkit.registry.fetch("nope") }.to raise_error(McpToolkit::Registry::UnknownResource)
    end

    it "fails loudly when a resource is missing its serializer" do
      McpToolkit.registry.register(:broken) do
        model Object
        scope { |_| [] }
      end
      expect do
        McpToolkit.registry.fetch("broken").resolve_relation(:root)
      end.to raise_error(McpToolkit::Resource::NotConfigured, /no serializer/)
    end
  end
end
