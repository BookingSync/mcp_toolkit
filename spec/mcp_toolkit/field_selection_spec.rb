# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::FieldSelection do
  # A Base-derived serializer that can describe its members, so validation is
  # exercised. `line_items` is aliased to the link key `items` to prove selection
  # matches on the LINK KEY, not the association name.
  let(:serializer) do
    Class.new(McpToolkit::Serializer::Base) do
      attributes :id, :name, :total
      has_one :account
      has_many :line_items, key: :items
      self.model_class = Class.new { def self.model_name = FakeModelName.new("things") }

      def self.name = "ThingSerializer"
    end
  end

  # A minimal resource wired to that serializer (FieldSelection only reads the
  # serializer's declared members off it).
  let(:resource) { McpToolkit::Resource.new(:things).tap { |r| r.serializer(serializer) } }

  describe ".build" do
    it "returns nil when nothing is requested" do
      expect(described_class.build(resource:, raw: nil)).to be_nil
      expect(described_class.build(resource:, raw: "")).to be_nil
      expect(described_class.build(resource:, raw: "  ")).to be_nil
      expect(described_class.build(resource:, raw: [])).to be_nil
    end

    it "parses a comma-separated string into de-duplicated, trimmed symbols" do
      selection = described_class.build(resource:, raw: " id , name ,id")

      expect(selection.names).to eq(%i[id name])
    end

    it "parses an array of names into symbols" do
      selection = described_class.build(resource:, raw: %w[id name])

      expect(selection.names).to eq(%i[id name])
    end

    it "accepts a relationship link key (not just attributes)" do
      selection = described_class.build(resource:, raw: "id,items")

      expect(selection.names).to eq(%i[id items])
    end

    it "rejects an unknown field with an actionable InvalidParams listing the selectable set" do
      expect do
        described_class.build(resource:, raw: "id,bogus")
      end.to raise_error(
        McpToolkit::Errors::InvalidParams,
        "unknown field(s): bogus. Selectable fields for this resource: account, id, items, name, total"
      )
    end

    it "skips validation for a serializer that cannot describe its members (opaque injection)" do
      opaque = Class.new do
        def self.serialize_one(_record, scope: nil); end
        def self.serialize_collection(_records, scope: nil, total_count: nil, limit: nil, offset: nil); end
      end
      opaque_resource = McpToolkit::Resource.new(:opaque).tap { |r| r.serializer(opaque) }

      selection = described_class.build(resource: opaque_resource, raw: "anything,goes")

      expect(selection.names).to eq(%i[anything goes])
    end
  end

  describe "#prune_record" do
    subject(:selection) { described_class.build(resource:, raw: fields) }

    let(:full) do
      { id: 7, name: "widget", total: 100, "links" => { "account" => 42, "items" => [1, 3] } }
    end

    context "when only attributes are selected" do
      let(:fields) { "id,name" }

      it "keeps the selected attributes and drops the links block entirely" do
        expect(selection.prune_record(full)).to eq(id: 7, name: "widget")
      end
    end

    context "when an attribute and a relationship are selected" do
      let(:fields) { "id,items" }

      it "keeps the attribute and narrows links to the selected key" do
        expect(selection.prune_record(full)).to eq(id: 7, "links" => { "items" => [1, 3] })
      end
    end
  end

  describe "#prune_collection" do
    subject(:selection) { described_class.build(resource:, raw: "id") }

    it "prunes each row and passes the meta block through untouched" do
      wrapper = {
        things: [
          { id: 1, name: "a", "links" => { "account" => 1 } },
          { id: 2, name: "b", "links" => { "account" => 2 } }
        ],
        meta: { total_count: 2, limit: 25, offset: 0 }
      }

      expect(selection.prune_collection(wrapper)).to eq(
        things: [{ id: 1 }, { id: 2 }],
        meta: { total_count: 2, limit: 25, offset: 0 }
      )
    end
  end
end
