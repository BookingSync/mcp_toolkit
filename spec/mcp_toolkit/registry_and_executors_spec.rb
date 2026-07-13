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
          "booking_id" => FakeRelation::Column.new(:integer),
          "price" => FakeRelation::Column.new(:integer)
        }
      end

      def self.primary_key
        "id"
      end

      def self.model_name
        FakeModelName.new("widgets")
      end
    end
  end

  let(:account) { :account_root }

  let(:rows) do
    [
      FakeRecord.new(id: 1, name: "alpha", booking_id: 10, price: 100),
      FakeRecord.new(id: 2, name: "beta", booking_id: 20, price: 200),
      FakeRecord.new(id: 3, name: "gamma", booking_id: 10, price: 300)
    ]
  end

  let(:relation) { FakeRelation.new(rows, table_name: "widgets", model: widget_model) }

  # The registered widgets resource is the shared fixture every executor example
  # drives; named so each `described_class.call(resource:, ...)` reads off it.
  subject(:resource) { McpToolkit.registry.fetch("widgets") }

  before do
    serializer = widget_serializer
    model = widget_model
    rel = relation
    McpToolkit.configure do |c|
      # No ActiveRecord in the gem's own suite — inject a sanitizer that escapes
      # LIKE wildcards the same way ActiveRecord's `sanitize_sql_like` would.
      c.sql_sanitizer = FakeSqlSanitizer.new
      c.registry.register(:widgets) do
        model model
        serializer serializer
        description "Test widgets."
        filterable booking_id: :booking_id, name: :name, price: :price
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

    it "treats a comma-separated equality value as an IN set (API v3 parity)" do
      result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: "10,20" } })

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2, 3])
    end

    it "treats an Array of scalars as an IN set (API v3 parity)" do
      result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: [10, 20] } })

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2, 3])
    end

    it "flattens comma-separated strings inside an Array into the IN set" do
      result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: ["10,20"] } })

      expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2, 3])
    end

    it "rejects an Array mixing operator conditions and bare values" do
      expect do
        described_class.call(
          resource:, scope_root: account,
          params: { filter: { price: [{ op: "gteq", value: 100 }, 200] } }
        )
      end.to raise_error(McpToolkit::Errors::InvalidParams, /only \{ op:, value: \} conditions or only bare values/)
    end

    it "rejects a mixed Array regardless of element order (bare value first)" do
      expect do
        described_class.call(
          resource:, scope_root: account,
          params: { filter: { price: [200, { op: "gteq", value: 100 }] } }
        )
      end.to raise_error(McpToolkit::Errors::InvalidParams, /only \{ op:, value: \} conditions or only bare values/)
    end

    describe "NULL filtering (API v3 parity)" do
      let(:rows) do
        [
          FakeRecord.new(id: 1, name: "alpha", booking_id: 10, price: 100),
          FakeRecord.new(id: 2, name: nil, booking_id: nil, price: 200)
        ]
      end

      it "treats the \"null\" token as IS NULL" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: "null" } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "treats a JSON null as IS NULL (not a silently-dropped filter)" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: nil } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "still treats an empty string as no filter" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: "" } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2])
      end

      it "resolves { op: \"eq\", value: \"null\" } to IS NULL (not IN (NULL))" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { booking_id: { op: "eq", value: "null" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "resolves { op: \"not_eq\", value: \"null\" } to IS NOT NULL" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { booking_id: { op: "not_eq", value: "null" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "accepts an Array value for an { op: \"in\" } condition" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: { op: "in", value: ["alpha"] } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "resolves { op: \"in\", value: \"null\" } to IS NULL (not IN (NULL))" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: { op: "in", value: "null" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "resolves an { op: \"eq\" } condition with a JSON null value to IS NULL" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { booking_id: { op: "eq", value: nil } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "keeps the \"null\" token LITERAL inside an IN set (SQL IN cannot match NULL)" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: %w[alpha null] } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "rejects a nil element inside an IN set with InvalidParams" do
        expect do
          described_class.call(resource:, scope_root: account, params: { filter: { name: ["alpha", nil] } })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /non-null scalar/)
      end

      it "rejects a null value for `matches` with InvalidParams (LIKE NULL can never match)" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { name: { op: "matches", value: "null" } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /does not accept a null value/)
      end

      it "rejects a null value for a comparison operator with InvalidParams" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { price: { op: "gt", value: "null" } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /does not accept a null value/)
      end
    end

    describe ":literal bare-value semantics (config.bare_filter_value_semantics — pre-gem API parity)" do
      let(:rows) do
        [
          FakeRecord.new(id: 1, name: "a,b", booking_id: 10, price: 100),
          FakeRecord.new(id: 2, name: "null", booking_id: nil, price: 200),
          FakeRecord.new(id: 3, name: "", booking_id: 30, price: 300)
        ]
      end

      before { McpToolkit.config.bare_filter_value_semantics = :literal }

      it "matches a comma-containing value literally (no IN split)" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { name: "a,b" } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "matches the string \"null\" literally (no NULL token)" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { name: "null" } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "matches empty-string rows for a bare \"\" (no skip)" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { name: "" } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([3])
      end

      it "hands an Array (including a nil element) to the adapter verbatim (IN + OR IS NULL)" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { booking_id: [10, nil] } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2])
      end

      it "still filters IS NULL for a bare JSON null (verbatim nil)" do
        result = described_class.call(resource:, scope_root: account, params: { filter: { booking_id: nil } })

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "still rejects an op-less Hash" do
        expect do
          described_class.call(resource:, scope_root: account, params: { filter: { name: { foo: 1 } } })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /unsupported filter value/)
      end

      it "leaves operator conditions untouched (same in both modes)" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { price: { op: "gteq", value: 200 } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2, 3])
      end
    end

    describe "companion-key filter requirements (Resource#filter_requirements)" do
      before do
        serializer = widget_serializer
        model = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:poly_widgets) do
            model model
            serializer serializer
            description "Widgets with a polymorphic-style companion requirement."
            filterable booking_id: :booking_id, name: :name
            filter_requirements booking_id: :name
            scope { |_root| rel }
          end
        end
      end

      subject(:poly_resource) { McpToolkit.registry.fetch("poly_widgets") }

      it "rejects the key without its companion, naming both (pre-gem API parity message)" do
        expect do
          described_class.call(resource: poly_resource, scope_root: account, params: { filter: { booking_id: 10 } })
        end.to raise_error(
          McpToolkit::Errors::InvalidParams,
          "filter attribute booking_id requires name to also be provided"
        )
      end

      it "accepts the key together with its companion" do
        result = described_class.call(
          resource: poly_resource, scope_root: account, params: { filter: { booking_id: 10, name: "alpha" } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "leaves the companion key usable on its own" do
        result = described_class.call(
          resource: poly_resource, scope_root: account, params: { filter: { name: "alpha" } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "rejects a companion whose value would be SKIPPED (\"\" under :tokenized) — no bypass" do
        expect do
          described_class.call(
            resource: poly_resource, scope_root: account, params: { filter: { booking_id: 10, name: "" } }
          )
        end.to raise_error(
          McpToolkit::Errors::InvalidParams,
          "filter attribute booking_id requires name to also be provided"
        )
      end
    end

    describe "config.filter_operator_overrides (pre-gem operator contract)" do
      before { McpToolkit.config.filter_operator_overrides = { string: %w[eq in] } }

      it "narrows the ENFORCED operator set for the overridden type" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { name: { op: "matches", value: "al" } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /not supported/)
      end

      it "keeps operators inside the overridden set working" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: { op: "in", value: "alpha" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1])
      end

      it "narrows the ADVERTISED operator set identically (schema and executor cannot disagree)" do
        schema = McpToolkit::ResourceSchema.call(resource)
        name_attribute = schema[:attributes].find { |a| a[:name] == :name }

        expect(name_attribute[:operators]).to eq(%w[eq in])
      end

      it "leaves non-overridden types on the gem's own sets" do
        expect(McpToolkit::Filtering.operators_for(:integer)).to eq(%w[eq not_eq gt gteq lt lteq])
      end
    end

    describe "operator support for column types outside the operator table" do
      let(:uuid_widget_model) do
        Class.new do
          def self.columns_hash
            {
              "id" => FakeRelation::Column.new(:uuid),
              "name" => FakeRelation::Column.new(:string),
              "booking_id" => FakeRelation::Column.new(:integer),
              "price" => FakeRelation::Column.new(:integer)
            }
          end
          def self.primary_key = "id"
          def self.model_name = FakeModelName.new("widgets")
        end
      end

      before do
        serializer = widget_serializer
        model = uuid_widget_model
        rel = FakeRelation.new(rows, table_name: "widgets", model: uuid_widget_model)
        McpToolkit.configure do |c|
          c.registry.register(:uuid_widgets) do
            model model
            serializer serializer
            description "Widgets with a uuid id."
            filterable id: :id
            scope { |_root| rel }
          end
        end
      end

      it "accepts eq / in on a uuid column instead of 'cannot be filtered with operators'" do
        result = described_class.call(
          resource: McpToolkit.registry.fetch("uuid_widgets"), scope_root: account,
          params: { filter: { id: { op: "in", value: "1,2" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2])
      end

      it "still rejects operators outside the eq/in fallback for such columns" do
        expect do
          described_class.call(
            resource: McpToolkit.registry.fetch("uuid_widgets"), scope_root: account,
            params: { filter: { id: { op: "gt", value: 1 } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /not supported/)
      end
    end

    describe "empty-string and malformed filter values" do
      let(:rows) do
        [
          FakeRecord.new(id: 1, name: "alpha", booking_id: 10, price: 100),
          FakeRecord.new(id: 2, name: "", booking_id: 20, price: 200)
        ]
      end

      it "matches rows whose value IS the empty string for { op: \"eq\", value: \"\" }" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: { op: "eq", value: "" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "rejects a Hash element inside an IN set with InvalidParams (was a query-time TypeError)" do
        expect do
          described_class.call(resource:, scope_root: account, params: { filter: { name: [{ foo: 1 }] } })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /non-null scalar/)
      end

      it "rejects a nested Array element inside an IN set with InvalidParams" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { price: [[{ op: "eq", value: 100 }]] } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /non-null scalar/)
      end

      it "rejects an op-less Hash as a bare filter value with InvalidParams" do
        expect do
          described_class.call(resource:, scope_root: account, params: { filter: { name: { foo: 1 } } })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /unsupported filter value/)
      end
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

    describe "sparse fieldsets (fields)" do
      it "returns only the requested attributes when given a comma-separated string" do
        result = described_class.call(resource:, scope_root: account, params: { fields: "id,name" })

        expect(result[:widgets]).to eq([{ id: 1, name: "alpha" }, { id: 2, name: "beta" }, { id: 3, name: "gamma" }])
        expect(result[:meta]).to eq(total_count: 3, limit: 25, offset: 0)
      end

      it "accepts an array of field names too" do
        result = described_class.call(resource:, scope_root: account, params: { fields: %w[id] })

        expect(result[:widgets]).to eq([{ id: 1 }, { id: 2 }, { id: 3 }])
      end

      it "rejects an unknown field with InvalidParams" do
        expect do
          described_class.call(resource:, scope_root: account, params: { fields: "id,bogus" })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /unknown field\(s\): bogus/)
      end
    end

    describe "operator-based (complex hash) filtering — API v3 parity" do
      it "applies a single { op:, value: } comparison condition" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { price: { op: "gteq", value: 200 } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2, 3])
      end

      it "ANDs an array of conditions into a range" do
        result = described_class.call(
          resource:, scope_root: account,
          params: { filter: { price: [{ op: "gteq", value: 150 }, { op: "lt", value: 300 }] } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "supports not_eq" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { booking_id: { op: "not_eq", value: 10 } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "supports case-insensitive substring matching on string columns" do
        result = described_class.call(
          resource:, scope_root: account, params: { filter: { name: { op: "matches", value: "ET" } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([2])
      end

      it "rejects an operator unsupported for the column's type" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { name: { op: "gt", value: "a" } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /not supported/)
      end

      it "rejects a condition with a blank operator" do
        expect do
          described_class.call(
            resource:, scope_root: account, params: { filter: { price: { op: "", value: 10 } } }
          )
        end.to raise_error(McpToolkit::Errors::InvalidParams, /operator is required/)
      end
    end

    describe "ordering by numeric vs non-numeric primary key (API v3 parity)" do
      # A relation that records which column(s) it was last ordered by.
      let(:ordering_relation_class) do
        Class.new(FakeRelation) do
          attr_reader :ordered_by

          def order(*columns)
            @ordered_by = columns.length == 1 ? columns.first : columns
            super
          end
        end
      end

      def register_resource_with_pk_type(pk_type, pk_name: "id")
        model = Class.new do
          define_singleton_method(:columns_hash) do
            { pk_name => FakeRelation::Column.new(pk_type), "created_at" => FakeRelation::Column.new(:datetime) }
          end
          define_singleton_method(:primary_key) { pk_name }
          def self.model_name = FakeModelName.new("things")
        end
        serializer = Class.new(McpToolkit::Serializer::Base) do
          attributes :id
          self.model_class = model
          def self.name = "ThingSerializer"
        end
        rel = ordering_relation_class.new([FakeRecord.new(id: 1, created_at: nil)], table_name: "things", model:)
        McpToolkit.configure do |c|
          c.registry.register(:things) do
            model model
            serializer serializer
            scope { |_root| rel }
          end
        end
        rel
      end

      it "orders by :id when the primary key is numeric" do
        rel = register_resource_with_pk_type(:integer)

        described_class.call(resource: McpToolkit.registry.fetch("things"), scope_root: account, params: {})

        expect(rel.ordered_by).to eq(:id)
      end

      it "orders by :created_at with the PK as tiebreaker when the primary key is non-numeric" do
        rel = register_resource_with_pk_type(:uuid)

        described_class.call(resource: McpToolkit.registry.fetch("things"), scope_root: account, params: {})

        # The PK tiebreaker restores a total order: rows bulk-inserted in one
        # transaction share a created_at, and offset pagination over a partial
        # order can duplicate or skip rows across pages.
        expect(rel.ordered_by).to eq(%i[created_at id])
      end

      it "reads the tiebreaker column off the model's primary key, not a hardcoded :id" do
        rel = register_resource_with_pk_type(:uuid, pk_name: "uuid")

        described_class.call(resource: McpToolkit.registry.fetch("things"), scope_root: account, params: {})

        expect(rel.ordered_by).to eq(%i[created_at uuid])
      end

      it "orders by the primary key alone under config.non_numeric_pk_order = :primary_key (pre-gem parity)" do
        rel = register_resource_with_pk_type(:uuid)
        McpToolkit.config.non_numeric_pk_order = :primary_key

        described_class.call(resource: McpToolkit.registry.fetch("things"), scope_root: account, params: {})

        expect(rel.ordered_by).to eq(:id)
      end
    end

    describe "custom filters (the Resource#filter seam)" do
      before do
        serializer = widget_serializer
        model = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:custom_widgets) do
            model model
            serializer serializer
            description "Widgets with a relational custom filter."
            filterable price: :price
            # A custom filter keyed OUTSIDE the equality allowlist: it applies an
            # arbitrary block to the scoped relation, reading a TOP-LEVEL request param.
            filter :for_booking, type: :integer, description: "Only widgets for this booking" do |relation, value|
              relation.where(booking_id: value)
            end
            scope { |_root| rel }
          end
        end
      end

      subject(:custom_resource) { McpToolkit.registry.fetch("custom_widgets") }

      it "applies the custom-filter block for a matching TOP-LEVEL request key" do
        result = described_class.call(resource: custom_resource, scope_root: account, params: { for_booking: 10 })

        expect(result[:widgets].map { |w| w[:id] }).to eq([1, 3])
      end

      it "is a no-op when the custom-filter key is absent or blank" do
        result = described_class.call(resource: custom_resource, scope_root: account, params: { for_booking: "" })

        expect(result[:widgets].map { |w| w[:id] }).to eq([1, 2, 3])
      end

      it "runs BEFORE and composes with the allowlist equality filters" do
        result = described_class.call(
          resource: custom_resource, scope_root: account,
          params: { for_booking: 10, filter: { price: { op: "gteq", value: 300 } } }
        )

        expect(result[:widgets].map { |w| w[:id] }).to eq([3])
      end

      it "does NOT expose the custom key through the equality allowlist" do
        expect do
          described_class.call(resource: custom_resource, scope_root: account, params: { filter: { for_booking: 10 } })
        end.to raise_error(McpToolkit::Errors::InvalidParams, /unknown filter attribute/)
      end
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

    it "honors a sparse `fields` selection, returning only the requested attributes" do
      result = described_class.call(resource:, scope_root: account, id: 2, fields: "id,name")

      expect(result).to eq(id: 2, name: "beta")
    end

    it "rejects an unknown `fields` name before the lookup runs" do
      expect do
        described_class.call(resource:, scope_root: account, id: 2, fields: "bogus")
      end.to raise_error(McpToolkit::Errors::InvalidParams, /unknown field\(s\): bogus/)
    end
  end

  # An injected serializer that predates the `fields:` kwarg (implements only the
  # two-arg contract). Sparse fieldsets must still work by PRUNING its output, so
  # the injection contract stays intact as the feature is added.
  describe "sparse fieldsets on a serializer without a `fields:` keyword (output pruning)" do
    let(:legacy_serializer) do
      Class.new do
        def self.serialize_one(record, scope: nil)
          { id: record.id, name: record.name, "links" => { "owner" => record.id } }
        end

        def self.serialize_collection(records, scope: nil, total_count: nil, limit: nil, offset: nil)
          rows = records.map { |r| serialize_one(r, scope:) }
          { widgets: rows, meta: { total_count: total_count || rows.size, limit:, offset: } }
        end
      end
    end

    before do
      serializer = legacy_serializer
      rel = relation
      McpToolkit.configure do |c|
        c.registry.register(:legacy_widgets) do
          model Object
          serializer serializer
          scope { |_root| rel }
        end
      end
    end

    subject(:legacy_resource) { McpToolkit.registry.fetch("legacy_widgets") }

    it "prunes GetExecutor output to the requested attribute, dropping links" do
      result = McpToolkit::GetExecutor.call(resource: legacy_resource, scope_root: account, id: 2, fields: "id")

      expect(result).to eq(id: 2)
    end

    it "prunes ListExecutor rows while leaving the meta block untouched" do
      result = McpToolkit::ListExecutor.call(resource: legacy_resource, scope_root: account, params: { fields: "id" })

      expect(result[:widgets]).to eq([{ id: 1 }, { id: 2 }, { id: 3 }])
      expect(result[:meta]).to include(limit: 25, offset: 0)
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
      expect(schema[:filters]).to eq(
        [
          { key: :booking_id, column: :booking_id, type: "integer", format: "integer" },
          { key: :name, column: :name, type: "string", format: "string" },
          { key: :price, column: :price, type: "integer", format: "integer" }
        ]
      )
    end

    it "advertises the per-attribute filter operators derived from the column type" do
      schema = described_class.call(resource)

      booking = schema[:attributes].find { |a| a[:name] == :booking_id }
      name = schema[:attributes].find { |a| a[:name] == :name }
      id = schema[:attributes].find { |a| a[:name] == :id }

      expect(booking[:operators]).to eq(%w[eq not_eq gt gteq lt lteq])
      # Pre-gem contract order (JSON arrays are ordered; byte-diffing clients see reorders).
      expect(name[:operators]).to eq(%w[eq in not_eq matches does_not_match])
      # A non-filterable attribute advertises an empty operator set.
      expect(id[:operators]).to eq([])
    end

    it "omits the note key for a resource without one (compacted, API parity)" do
      expect(described_class.call(resource)).not_to have_key(:note)
    end

    it "advertises an empty resource_filters list for a resource without custom filters" do
      expect(described_class.call(resource)).to include(resource_filters: [])
    end

    it "advertises sparse fieldset support (API parity key)" do
      expect(described_class.call(resource)).to include(sparse_fieldsets: true)
    end

    it "builds ready-to-use filter_examples from the resource's own attributes" do
      examples = described_class.call(resource)[:filter_examples]

      # widgets: name (string) => equality example; price/booking_id (integer,
      # gt-capable) => comparison + range examples; no relationship filter here.
      expect(examples).to include(name: "...")
      expect(examples).to include(booking_id: { op: "gt", value: 1 })
      expect(examples).to include(booking_id: [{ op: "gteq", value: 1 }, { op: "lt", value: 1 }])
    end

    context "with a filterable relationship foreign key and a companion requirement" do
      let(:noted_widget_serializer) do
        model = widget_model
        Class.new(McpToolkit::Serializer::Base) do
          attributes :id, :booking_id
          has_one :booking
          self.model_class = model
          def self.name = "RelWidgetSerializer"
        end
      end

      before do
        serializer = noted_widget_serializer
        model = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:rel_widgets) do
            model model
            serializer serializer
            description "Widgets with a filterable relationship."
            # The requirement's companion must itself be filterable (see
            # Resource#filter_requirements) — here booking_type is aliased to a
            # backing column so the advertised pair is actually acceptable.
            filterable booking_id: :booking_id, booking: :booking_id, booking_type: :name
            filter_requirements booking_id: :booking_type
            scope { |_root| rel }
          end
        end
      end

      it "describes HOW to filter by the relationship: keys, type, operators and requires" do
        schema = described_class.call(McpToolkit.registry.fetch("rel_widgets"))
        relationship = schema[:relationships].find { |r| r[:name] == "booking" }

        expect(relationship[:filter]).to eq(
          keys: %i[booking_id booking],
          type: "integer",
          operators: %w[eq not_eq gt gteq lt lteq],
          requires: :booking_type
        )
      end

      it "includes a relationship example carrying the required companion key (pre-gem sample value)" do
        examples = described_class.call(McpToolkit.registry.fetch("rel_widgets"))[:filter_examples]

        expect(examples).to include(booking_id: 1, booking_type: "User")
      end
    end

    context "with custom filters (the Resource#filter seam)" do
      before do
        serializer = widget_serializer
        model = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:filtered_widgets) do
            model model
            serializer serializer
            description "Widgets with a relational custom filter."
            filter :for_booking, type: :integer, description: "Only widgets for this booking" do |relation, value|
              relation.where(booking_id: value)
            end
            scope { |_root| rel }
          end
        end
      end

      it "surfaces each custom filter's name, type and description under resource_filters" do
        schema = described_class.call(McpToolkit.registry.fetch("filtered_widgets"))

        expect(schema[:resource_filters]).to eq(
          [{ name: "for_booking", type: "integer", description: "Only widgets for this booking" }]
        )
      end
    end

    context "with a resource note" do
      before do
        serializer = widget_serializer
        model = widget_model
        rel = relation
        McpToolkit.configure do |c|
          c.registry.register(:noted_widgets) do
            model model
            serializer serializer
            description "Noted widgets."
            note "Internal debugging resource; do not interpret without domain knowledge."
            scope { |_root| rel }
          end
        end
      end

      it "passes the resource note through to the schema" do
        schema = described_class.call(McpToolkit.registry.fetch("noted_widgets"))

        expect(schema[:note]).to eq("Internal debugging resource; do not interpret without domain knowledge.")
      end
    end

    # The DX gap this closes: a `scheduled_notifications.notification` link is
    # discoverably the `notifications` resource (callable via list/get) rather than
    # a name the caller has to guess.
    context "relationship target resource resolution" do
      let(:notification_model) do
        Class.new do
          def self.columns_hash
            { "id" => FakeRelation::Column.new(:integer), "name" => FakeRelation::Column.new(:string) }
          end
          def self.primary_key = "id"
          def self.model_name = FakeModelName.new("notifications")
        end
      end

      let(:notification_serializer) do
        model = notification_model
        Class.new(McpToolkit::Serializer::Base) do
          attributes :id, :name
          self.model_class = model
          def self.name = "NotificationSerializer"
        end
      end

      let(:scheduled_notification_serializer) do
        Class.new(McpToolkit::Serializer::Base) do
          attributes :id
          has_one :notification            # singular link -> plural `notifications` resource
          has_many :orphans                # no registered target
          has_one :subject_record, polymorphic: true
          self.model_class = Object
          def self.name = "ScheduledNotificationSerializer"
        end
      end

      before do
        n_model = notification_model
        n_serializer = notification_serializer
        sn_serializer = scheduled_notification_serializer
        McpToolkit.configure do |c|
          c.registry.register(:notifications) do
            model n_model
            serializer n_serializer
            description "Notifications."
            scope { |_root| [] }
          end
          c.registry.register(:scheduled_notifications) do
            model Object
            serializer sn_serializer
            description "Scheduled notifications."
            scope { |_root| [] }
          end
        end
      end

      subject(:schema) do
        described_class.call(McpToolkit.registry.fetch("scheduled_notifications"), registry: McpToolkit.registry)
      end

      it "names the target resource a singular link resolves to (both the legacy and additive keys)" do
        relationship = schema[:relationships].find { |r| r[:name] == "notification" }

        expect(relationship).to include(
          name: "notification",
          kind: "has_one",
          polymorphic: false,
          resource: "notifications",
          target_resource: "notifications"
        )
      end

      it "emits a null legacy `resource` and omits `target_resource` when no resource matches" do
        relationship = schema[:relationships].find { |r| r[:name] == "orphans" }

        # `resource` / `filter` are always-present nullable keys (API parity);
        # `target_resource` stays omit-when-unresolved (its 0.4.0 contract).
        expect(relationship.keys).to contain_exactly(:name, :kind, :polymorphic, :resource, :filter)
        expect(relationship).to include(resource: nil, filter: nil)
      end

      it "leaves a polymorphic link unresolved (no single target resource)" do
        relationship = schema[:relationships].find { |r| r[:name] == "subject_record" }

        expect(relationship).to include(polymorphic: true)
        expect(relationship).not_to have_key(:target_resource)
      end
    end
  end

  describe McpToolkit::Registry do
    it "raises UnknownResource for an unregistered name" do
      expect { McpToolkit.registry.fetch("nope") }.to raise_error(McpToolkit::Registry::UnknownResource)
    end

    it "suggests the closest registered name on a near-miss (did you mean)" do
      expect { McpToolkit.registry.fetch("widget") }.to raise_error(
        McpToolkit::Registry::UnknownResource, /Did you mean "widgets"\?/
      )
    end

    it "lists the registered resources when the catalog is short" do
      expect { McpToolkit.registry.fetch("zzz") }.to raise_error(
        McpToolkit::Registry::UnknownResource, /Registered resources: "widgets"\./
      )
    end

    it "suggests a near-miss via UnknownResourceMessage's edit-distance fallback (no did_you_mean)" do
      resource_names = %w[notifications scheduled_notifications]
      message = McpToolkit::UnknownResourceMessage.new("notification", resource_names)

      expect(message.send(:fallback_suggestions, "notification", resource_names)).to include("notifications")
    end

    describe "required scope resolution" do
      subject(:registry) { McpToolkit::Registry.new }

      def register_resource(name, &)
        registry.register(name, &)
        registry.fetch(name.to_s)
      end

      it "uses a resource's own required_permissions_scope when declared" do
        resource = register_resource(:scoped) { required_permissions_scope "widgets__read" }

        expect(registry.required_scope_for(resource)).to eq("widgets__read")
      end

      it "falls back to the registry default for a resource without its own scope" do
        registry.default_required_permissions_scope "app__read"
        resource = register_resource(:unscoped) { description "no scope of its own" }

        expect(registry.required_scope_for(resource)).to eq("app__read")
      end

      it "prefers a resource's own scope over the registry default" do
        registry.default_required_permissions_scope "app__read"
        resource = register_resource(:own) { required_permissions_scope "own__read" }

        expect(registry.required_scope_for(resource)).to eq("own__read")
      end

      it "returns nil (no scope required) with neither a default nor a resource scope" do
        resource = register_resource(:open) { description "open" }

        expect(registry.required_scope_for(resource)).to be_nil
      end

      it "preserves the default scope across reset! (declared in configure, not to_prepare)" do
        registry.default_required_permissions_scope "app__read"
        registry.reset!

        expect(registry.default_required_permissions_scope).to eq("app__read")
        expect(registry.resources).to be_empty
      end
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
