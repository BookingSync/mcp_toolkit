# frozen_string_literal: true

module McpToolkit
  # Descriptor for a single read-only resource exposed via the MCP server. Built
  # via `McpToolkit.registry.register`; consumed by the List/Get executors and the
  # resource_schema tool. Extracted from bsa-notifications' `McpServer::Resource`.
  #
  # The `scope_block` is the account-rooting relation: it receives the resolved
  # local scope root (typically an `Account`) and MUST return a relation already
  # scoped so that every row belongs to that root (directly via a foreign key, or
  # transitively through an owning record). This is the single tenancy chokepoint —
  # every `get`/`list` query roots on it.
  #
  # The `serializer` is INJECTABLE per resource: it may be a subclass of the gem's
  # `McpToolkit::Serializer::Base`, or any class satisfying the serializer contract
  # (`serialize_one` / `serialize_collection`) — e.g. an existing API- or
  # Prometheus-derived serializer.
  class Resource
    class NotConfigured < StandardError; end

    attr_reader :name

    def initialize(name)
      @name = name.to_s
      @model = nil
      @serializer = nil
      @scope_block = nil
      @description = nil
      @filterable = {}
    end

    def model(klass = nil)
      @model = klass if klass
      @model
    end

    def serializer(klass = nil)
      @serializer = klass if klass
      @serializer
    end

    def scope(&block)
      @scope_block = block if block
      @scope_block
    end

    def description(text = nil)
      @description = text if text
      @description
    end

    # Declares the per-attribute equality filters this resource accepts on the
    # `list` tool. Each entry maps a REQUEST-FACING filter key to the backing
    # DATABASE COLUMN the equality WHERE is applied to. The mapping is what lets the
    # consumer-facing key differ from the storage column (e.g. exposing a synced
    # foreign key under its public name):
    #
    #   filterable booking_id: :synced_booking_id
    #
    # Unmapped/unknown keys are rejected by the list executor, never silently
    # dropped, so a typo surfaces as actionable feedback.
    def filterable(mapping = nil)
      return @filterable if mapping.nil?

      mapping.each do |request_key, column|
        @filterable[request_key.to_sym] = column.to_sym
      end
      @filterable
    end

    # Request-facing filter keys (symbols, sorted) this resource can be filtered
    # by. Surfaced via the `resource_schema` tool.
    def filterable_keys
      @filterable.keys.sort
    end

    # Request-facing filter key (symbol) => backing column (symbol). Consumed by
    # the list executor to build the WHERE clause.
    def filterable_columns
      @filterable
    end

    # The account-scoped relation for this resource. Raises if misconfigured so a
    # registry mistake fails loudly rather than leaking an unscoped query.
    def resolve_relation(scope_root)
      raise NotConfigured, "resource #{@name.inspect} has no scope block" unless @scope_block
      raise NotConfigured, "resource #{@name.inspect} has no model" unless @model
      raise NotConfigured, "resource #{@name.inspect} has no serializer" unless @serializer

      @scope_block.call(scope_root)
    end

    # Serialized attribute names (the response shape), read off the serializer's
    # declared attributes. Requires a serializer that exposes `declared_attributes`
    # (the gem's base does); resource_schema degrades gracefully otherwise.
    def attribute_names
      return [] unless @serializer.respond_to?(:declared_attributes)

      @serializer.declared_attributes.map(&:to_sym)
    end

    # Association descriptors (the `links` shape) read off the serializer.
    def association_descriptors
      return [] unless @serializer.respond_to?(:declared_associations)

      @serializer.declared_associations
    end
  end
end
