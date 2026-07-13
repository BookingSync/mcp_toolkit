# frozen_string_literal: true

require "spec_helper"
require "active_record"

# The production filter path builds REAL Arel nodes (Filtering.predicate_for's
# arel_table branch); the rest of the suite exercises the in-memory Predicate
# fake instead. This spec renders the actual Arel SQL so the core claims —
# `IS NULL` (never `IN (NULL)`) for eq/in against null, IN sets for arrays and
# comma strings — are pinned against Arel itself, not against the fake's model
# of it.
RSpec.describe McpToolkit::Filtering do
  # The minimal quoting surface Arel::Visitors::ToSql needs; matches the
  # ANSI-style quoting real adapters produce for these literals.
  let(:fake_connection) do
    Class.new do
      def quote_table_name(name) = %("#{name}")
      def quote_column_name(name) = %("#{name}")

      def quote(value)
        case value
        when nil then "NULL"
        when String then "'#{value}'"
        else value.to_s
        end
      end

      def in_clause_length = nil
      def sanitize_as_sql_comment(comment) = comment
      def cast_bound_value(value) = value
    end.new
  end

  let(:arel_table) { Arel::Table.new("widgets") }

  let(:model) do
    table = arel_table
    Class.new do
      define_singleton_method(:arel_table) { table }

      def self.columns_hash
        {
          "name" => FakeRelation::Column.new(:string),
          "price" => FakeRelation::Column.new(:integer)
        }
      end
    end
  end

  # Captures the Arel node the production path hands to `relation.where`.
  let(:relation) do
    m = model
    Class.new do
      define_method(:model) { m }
      attr_reader :last_predicate

      def where(predicate)
        @last_predicate = predicate
        self
      end
    end.new
  end

  before { McpToolkit.configure { |c| c.sql_sanitizer = FakeSqlSanitizer.new } }

  def sql_for(column, value)
    described_class.apply(relation, column, value)
    visitor = Arel::Visitors::ToSql.new(fake_connection)
    visitor.accept(relation.last_predicate, Arel::Collectors::SQLString.new).value
  end

  it "renders eq + \"null\" as IS NULL, never IN (NULL)" do
    sql = sql_for(:name, { op: "eq", value: "null" })

    expect(sql).to eq(%("widgets"."name" IS NULL))
  end

  it "renders eq + a JSON null as IS NULL" do
    expect(sql_for(:name, { op: "eq", value: nil })).to eq(%("widgets"."name" IS NULL))
  end

  it "renders in + \"null\" as IS NULL" do
    expect(sql_for(:name, { op: "in", value: "null" })).to eq(%("widgets"."name" IS NULL))
  end

  it "renders not_eq + \"null\" as IS NOT NULL" do
    expect(sql_for(:name, { op: "not_eq", value: "null" })).to eq(%("widgets"."name" IS NOT NULL))
  end

  it "renders an eq comma-separated value as an IN set" do
    expect(sql_for(:name, { op: "eq", value: "a,b" })).to eq(%("widgets"."name" IN ('a', 'b')))
  end

  it "renders an in Array value as an IN set" do
    expect(sql_for(:name, { op: "in", value: %w[a b] })).to eq(%("widgets"."name" IN ('a', 'b')))
  end

  it "renders a comparison operator against the raw value" do
    expect(sql_for(:price, { op: "gteq", value: 100 })).to eq(%("widgets"."price" >= 100))
  end

  it "renders matches as a wildcard-wrapped LIKE" do
    expect(sql_for(:name, { op: "matches", value: "al" })).to match(/LIKE '%al%'/i)
  end

  describe "the bare (non-operator) path hands ActiveRecord a where-hash" do
    it "passes nil for a \"null\" value (AR renders IS NULL)" do
      described_class.apply(relation, :name, "null")

      expect(relation.last_predicate).to eq(name: nil)
    end

    it "passes the scalar Array for an IN set (AR renders IN, with OR IS NULL handling)" do
      described_class.apply(relation, :name, %w[a b])

      expect(relation.last_predicate).to eq(name: %w[a b])
    end
  end
end
