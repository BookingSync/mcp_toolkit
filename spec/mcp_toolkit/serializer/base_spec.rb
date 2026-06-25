# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Serializer::Base do
  subject(:serializer) do
    model = order_model
    Class.new(described_class) do
      attributes :id, :total, :created_at
      has_one :account, foreign_key: :synced_account_id
      has_one :owner, polymorphic: true
      has_many :line_items
      self.model_class = model

      def self.name
        "OrderSerializer"
      end
    end
  end

  let(:order_model) do
    Class.new do
      def self.model_name
        FakeModelName.new("orders")
      end
    end
  end

  describe ".serialize_one" do
    it "is nil-safe" do
      expect(serializer.serialize_one(nil)).to be_nil
    end

    it "emits declared attributes (symbol keys) plus a sorted string-keyed links hash" do
      record = FakeRecord.new(
        id: 7,
        total: 100,
        created_at: Time.utc(2026, 6, 18, 12, 0, 0),
        synced_account_id: 42,
        owner_id: 5,
        owner_type: "User",
        line_items: FakeRelation.new([FakeRecord.new(id: 3), FakeRecord.new(id: 1)])
      )

      hash = serializer.serialize_one(record)

      # attributes preserved, timestamps rendered iso8601(6)
      expect(hash[:id]).to eq(7)
      expect(hash[:total]).to eq(100)
      expect(hash[:created_at]).to eq("2026-06-18T12:00:00.000000Z")

      # links: string key, alphabetically sorted associations
      links = hash["links"]
      expect(links.keys).to eq(%w[account line_items owner])
      expect(links["account"]).to eq(42) # foreign_key override
      expect(links["owner"]).to eq(id: 5, type: "User") # polymorphic shape
      expect(links["line_items"]).to eq([1, 3]) # has_many -> sorted ids
    end
  end

  describe ".serialize_collection" do
    it "wraps rows under the plural root with a meta block" do
      records = [FakeRecord.new(
        id: 1, total: 10, created_at: nil,
        synced_account_id: 1, owner_id: nil, owner_type: nil,
        line_items: FakeRelation.new([])
      )]

      result = serializer.serialize_collection(records, total_count: 50, limit: 25, offset: 0)

      expect(result.keys).to contain_exactly(:orders, :meta)
      expect(result[:orders].size).to eq(1)
      expect(result[:meta]).to eq(total_count: 50, limit: 25, offset: 0)
    end
  end

  describe "injection: a custom serializer satisfying only the contract" do
    # A serializer that is NOT a subclass of Base — it only implements the two
    # contract methods. Stands in for an app's existing serializer. The executor
    # must work with it unchanged.
    subject(:custom_serializer) do
      Class.new do
        def self.serialize_one(record, scope: nil)
          { custom: true, id: record.id, scope: scope }
        end

        def self.serialize_collection(records, scope: nil, total_count: nil, limit: nil, offset: nil)
          { rows: records.map(&:id), meta: { total_count:, limit:, offset:, scope: } }
        end
      end
    end

    it "is driven by GetExecutor exactly like the base serializer" do
      custom = custom_serializer
      McpToolkit.configure do |c|
        c.registry.register(:things) do
          model Object
          serializer custom
          scope { |_root| FakeRelation.new([FakeRecord.new(id: 9)]) }
        end
      end

      result = McpToolkit::GetExecutor.call(
        resource: McpToolkit.registry.fetch("things"), scope_root: :acct, id: 9
      )

      expect(result).to eq(custom: true, id: 9, scope: :acct)
    end
  end
end
