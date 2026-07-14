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
  # ANSI-style quoting real adapters produce for these literals — INCLUDING
  # doubling embedded single quotes, so a hostile payload renders as an escaped
  # string literal rather than breaking out. A non-escaping fake would make the
  # injection-safety examples below pass vacuously (Codex review, 07-14).
  let(:fake_connection) do
    Class.new do
      def quote_table_name(name) = %("#{name}")
      def quote_column_name(name) = %("#{name}")

      def quote(value)
        case value
        when nil then "NULL"
        when String then "'#{value.gsub("'", "''")}'"
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

  # Injection-safety regression tests (Codex review, 07-14). These render REAL
  # Arel SQL through a correctly-escaping connection, so a payload that tried to
  # break out of a string literal would show up as broken (un-doubled) SQL here.
  describe "injection safety" do
    it "keeps a quote-breakout eq payload inside an escaped string literal" do
      sql = sql_for(:name, { op: "eq", value: "x') OR 1=1 --" })

      expect(sql).to eq(%q{"widgets"."name" IN ('x'') OR 1=1 --')})
    end

    it "hands a hostile bare value to ActiveRecord as data, never spliced into SQL" do
      described_class.apply(relation, :name, "x' OR 1=1 --")

      expect(relation.last_predicate).to eq(name: "x' OR 1=1 --")
    end

    it "escapes LIKE wildcards (sanitizer) and quotes (adapter) in a matches value" do
      sql = sql_for(:name, { op: "matches", value: "50%_off'" })

      expect(sql).to include('\%').and(include('\_')).and(include("''"))
    end

    # The dangerous seam: a host-configured operator outside the safe Arel
    # predications would be public_send to an attribute with the request value
    # passed through verbatim (Codex's `extract` example). Both guards below
    # must hold.
    it "refuses to dispatch an operator outside the Arel predications (predicate_for guard)" do
      expect { described_class.predicate_for(relation, :name, "extract", "epoch", config: McpToolkit.config) }
        .to raise_error(McpToolkit::Errors::InvalidParams, /not a supported filter operator/)
    end

    it "rejects an unsafe operator override at config time (config guard)" do
      expect { McpToolkit.configure { |c| c.filter_operator_overrides = { datetime: ["extract"] } } }
        .to raise_error(ArgumentError, /unsupported operator/)
    end

    it "accepts an override that restricts to safe predications" do
      expect { McpToolkit.configure { |c| c.filter_operator_overrides = { text: %w[eq in] } } }
        .not_to raise_error
    end
  end

  describe "max_filter_values caps unbounded IN sets and condition arrays" do
    it "rejects an IN set larger than the cap" do
      McpToolkit.configure { |c| c.max_filter_values = 3 }

      expect { described_class.apply(relation, :name, { op: "in", value: %w[a b c d] }) }
        .to raise_error(McpToolkit::Errors::InvalidParams, /at most 3 values/)
    end

    it "rejects a comma-tokenized bare value larger than the cap" do
      McpToolkit.configure { |c| c.max_filter_values = 2 }

      expect { described_class.apply(relation, :name, "a,b,c") }
        .to raise_error(McpToolkit::Errors::InvalidParams, /at most 2 values/)
    end

    it "rejects a condition array longer than the cap" do
      McpToolkit.configure { |c| c.max_filter_values = 1 }

      expect { described_class.apply(relation, :price, [{ op: "gteq", value: 1 }, { op: "lt", value: 9 }]) }
        .to raise_error(McpToolkit::Errors::InvalidParams, /at most 1 values or conditions/)
    end

    it "allows a set within the cap" do
      McpToolkit.configure { |c| c.max_filter_values = 3 }

      expect { described_class.apply(relation, :name, { op: "in", value: %w[a b c] }) }.not_to raise_error
    end

    it "does not cap when nil" do
      McpToolkit.configure { |c| c.max_filter_values = nil }

      expect { described_class.apply(relation, :name, { op: "in", value: %w[a b c d e f] }) }.not_to raise_error
    end
  end
end
