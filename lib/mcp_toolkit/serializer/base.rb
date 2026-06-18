# frozen_string_literal: true

module McpToolkit
  module Serializer
    # The DEFAULT serializer base shipped by the toolkit, extracted from
    # bsa-notifications' `Mcp::BaseSerializer`. A self-contained re-implementation
    # of the subset of an AMS-style serializer the MCP wire format depends on, with
    # NO dependency on `active_model_serializers` / `fast_jsonapi`.
    #
    # ## The injection contract
    #
    # The executors (`ListExecutor` / `GetExecutor`) only ever call two class
    # methods on a resource's serializer:
    #
    #   serializer.serialize_one(record, scope:)
    #     # => Hash (a single record's shape), or nil for a nil record
    #
    #   serializer.serialize_collection(records, scope:, total_count:, limit:, offset:)
    #     # => { <root_key> => [ <record_hash>, ... ],
    #     #      meta: { total_count:, limit:, offset: } }
    #
    # ANY class implementing those two methods can be registered as a resource's
    # serializer — that is the seam that lets an app's existing API- or
    # Prometheus-derived serializers slot in unchanged alongside this base. The
    # `resource_schema` tool additionally reads `declared_attributes` and
    # `declared_associations` off the serializer (for shape discovery); a custom
    # serializer that wants to power `resource_schema` should expose those too, but
    # they are not required for `get` / `list`.
    #
    # `scope` is whatever the serializer needs (typically the account); it may be
    # nil for models without translations.
    #
    # ## Output shape
    #
    # A single record serializes to:
    #
    #   { <attr> => <value>, ..., "links" => { "<assoc>" => <id|[ids]|{id:,type:}|nil> } }
    #
    # * Declared `attributes` are emitted as symbol keys, in declaration order
    #   (an instance method named after the attribute overrides the column value).
    # * `"links"` is a string key whose value is a Hash with string keys, one per
    #   declared association, sorted alphabetically.
    #   - has_one / belongs_to whose FK lives on the record => the raw id (or nil)
    #   - polymorphic has_one / belongs_to => { id: <id>, type: <type> }
    #   - has_many => a sorted Array of associated ids ([] when none)
    # * created_at / updated_at, when present, are rendered as iso8601(6).
    #
    # A collection serializes to:
    #
    #   { <plural_resource_name>: [ <record_hash>, ... ],
    #     meta: { total_count:, limit:, offset: } }
    class Base
      TIMESTAMP_COLUMNS = %i[created_at updated_at].freeze
      HIGH_PRECISION_FOR_TIMESTAMPS = 6

      # ---- class-level DSL -------------------------------------------------

      Association = Struct.new(:name, :type, :key, :serializer, :polymorphic, :foreign_key, keyword_init: true) do
        # Public-facing key used inside the `links` hash.
        def links_key
          (key || name).to_s
        end
      end

      class << self
        def attributes(*names)
          names.each { |name| declared_attributes << name.to_sym }
        end

        # belongs_to / has_one - single id (or {id:,type:} when polymorphic).
        #
        # `foreign_key:` overrides the FK method read for the id (defaults to
        # `<name>_id`). Use it when the model's FK column doesn't follow the
        # `<name>_id` convention - e.g.
        # `has_one :account, foreign_key: :synced_account_id` so the link reports
        # the central account id straight off the already-loaded column.
        def has_one(name, key: nil, root: nil, serializer: nil, polymorphic: false, foreign_key: nil)
          declared_associations << Association.new(
            name: name.to_sym, type: :has_one, key: key || root, serializer:, polymorphic:, foreign_key:
          )
        end

        # has_many / has_and_belongs_to_many - sorted array of ids.
        def has_many(name, key: nil, root: nil, serializer: nil)
          declared_associations << Association.new(
            name: name.to_sym, type: :has_many, key: key || root, serializer:, polymorphic: false
          )
        end

        # Declares attributes whose value is a `{ locale => translation }` hash.
        # An instance method is defined for each attribute that delegates to
        # `#translate`. Only meaningful for Globalize models; harmless otherwise
        # (returns {}).
        def translates(*names)
          names.each do |name|
            declared_attributes << name.to_sym unless declared_attributes.include?(name.to_sym)
            define_method(name) { translate(name) }
          end
        end

        def declared_attributes
          @declared_attributes ||= []
        end

        def declared_associations
          @declared_associations ||= []
        end

        # ---- entry points used by the executors (the injection contract) -----

        # Serialize a single record to its attributes+links hash. nil-safe.
        def serialize_one(record, scope: nil)
          return nil if record.nil?

          new(record, scope:).serializable_hash
        end

        # Serialize an array of records to the index wrapper, keyed by the
        # pluralized resource name, with a `meta` pagination block.
        def serialize_collection(records, scope: nil, total_count: nil, limit: nil, offset: nil)
          rows = Array(records).map { |record| new(record, scope:).serializable_hash }
          {
            root_key => rows,
            meta: { total_count: total_count.nil? ? rows.size : total_count, limit:, offset: }
          }
        end

        # Pluralized resource name used as the collection root key, derived from
        # the serialized model (`model.model_name.plural`).
        def root_key
          model_class.model_name.plural.to_sym
        end

        # Infer the serialized model from the serializer class name by stripping a
        # trailing "Serializer" and the host namespace, e.g.
        #   Mcp::NotificationSerializer            -> Notification
        #   Mcp::PushNotifications::FilterSerializer -> PushNotifications::Filter
        # Subclasses whose name doesn't follow the convention set `model_class`.
        def model_class
          @model_class ||= begin
            without_suffix = name.delete_suffix("Serializer")
            # Drop the leading serializer namespace segment (e.g. "Mcp::") so the
            # remainder names the model. If there is no namespace, use as-is.
            without_namespace = without_suffix.sub(/\A[^:]+::/, "")
            (without_namespace.empty? ? without_suffix : without_namespace).constantize
          end
        end

        # Lets subclasses point at a model whose name doesn't follow the
        # convention (e.g. namespacing differences).
        attr_writer :model_class
      end

      # ---- instance API ----------------------------------------------------

      attr_reader :object, :scope

      def initialize(object, scope: nil)
        @object = object
        @scope = scope
      end

      def serializable_hash
        hash = {}
        self.class.declared_attributes.each do |attr|
          hash[attr] = read_attribute(attr)
        end
        apply_high_precision_timestamps(hash)
        hash["links"] = links
        hash
      end
      alias as_json serializable_hash

      private

      def read_attribute(attr)
        # An instance method named after the attribute overrides the column value
        # (AMS convention). Globalize `translates` uses exactly this hook.
        if respond_to?(attr, true) && method(attr).owner != McpToolkit::Serializer::Base
          public_send(attr)
        else
          object.public_send(attr)
        end
      end

      def apply_high_precision_timestamps(hash)
        TIMESTAMP_COLUMNS.each do |column|
          value = hash[column]
          hash[column] = value.iso8601(HIGH_PRECISION_FOR_TIMESTAMPS) if value.present? && value.respond_to?(:iso8601)
        end
      end

      # Builds the `links` hash: association links_key => ids, sorted.
      def links
        pairs = self.class.declared_associations.map do |association|
          [association.links_key, serialize_ids(association)]
        end
        pairs.sort_by(&:first).to_h
      end

      # Serializes an association to its id(s):
      #   * FK present on the record -> the raw id (polymorphic -> {id:,type:})
      #   * otherwise load the association -> sorted array of ids (has_many)
      #     or single id (has_one).
      def serialize_ids(association)
        fk_method = association.foreign_key || :"#{association.name}_id"

        if object.respond_to?(fk_method)
          if association.polymorphic
            { id: object.public_send(fk_method), type: object.public_send(:"#{association.name}_type") }
          else
            object.public_send(fk_method)
          end
        else
          associated = object.public_send(association.name)
          if associated.respond_to?(:to_ary) || associated.respond_to?(:pluck)
            associated.pluck(:id).sort
          elsif associated
            associated.id
          end
        end
      end

      # Globalize-backed translation: `{ locale => value }`, restricted to the
      # account's selected locales when a scope account is present. Returns {} when
      # the model is not translatable.
      def translate(attribute)
        return {} unless object.respond_to?(:"#{attribute}_translations")

        translations = object.public_send(:"#{attribute}_translations") || {}
        locales = scope_locales
        result = {}
        translations.each do |locale, value|
          locale = locale.to_sym
          next if locales&.exclude?(locale)
          next if value.blank?

          result[locale] = value
        end
        result
      end

      # Locales to restrict translations to. nil means "no restriction" (emit all
      # available translations).
      def scope_locales
        return nil if scope.nil?
        return nil unless scope.respond_to?(:selected_locales)

        selected = scope.selected_locales
        return nil if selected.blank?

        Array(selected).map(&:to_sym)
      end
    end
  end
end
