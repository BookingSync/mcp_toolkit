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
      # A relation that records which column it was last ordered by.
      let(:ordering_relation_class) do
        Class.new(FakeRelation) do
          attr_reader :ordered_by

          def order(column)
            @ordered_by = column
            super
          end
        end
      end

      def register_resource_with_pk_type(pk_type)
        model = Class.new do
          define_singleton_method(:columns_hash) do
            { "id" => FakeRelation::Column.new(pk_type), "created_at" => FakeRelation::Column.new(:datetime) }
          end
          def self.primary_key = "id"
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

      it "orders by :created_at when the primary key is non-numeric" do
        rel = register_resource_with_pk_type(:uuid)

        described_class.call(resource: McpToolkit.registry.fetch("things"), scope_root: account, params: {})

        expect(rel.ordered_by).to eq(:created_at)
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

      it "names the target resource a singular link resolves to, with a name-attribute hint" do
        relationship = schema[:relationships].find { |r| r[:name] == "notification" }

        expect(relationship).to include(
          name: "notification",
          kind: "has_one",
          polymorphic: false,
          target_resource: "notifications",
          target_name_attribute: "name"
        )
      end

      it "omits target fields (additive/backward-compatible) when no resource matches" do
        relationship = schema[:relationships].find { |r| r[:name] == "orphans" }

        expect(relationship.keys).to contain_exactly(:name, :kind, :polymorphic)
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

    it "keeps its edit-distance fallback working without did_you_mean" do
      registry = McpToolkit::Registry.new
      registry.register(:notifications) { description "n" }
      registry.register(:scheduled_notifications) { description "s" }

      expect(registry.send(:fallback_suggestions, "notification", registry.resource_names))
        .to include("notifications")
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
