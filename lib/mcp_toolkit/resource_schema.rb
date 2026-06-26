# frozen_string_literal: true

# Builds a machine-readable schema for a single registered resource: its
# serialized attributes (the response shape) with column types, and its
# relationships (the `links` shape). Powers the `resource_schema` discovery tool
# so an MCP client can learn a resource's shape without trial and error.
#
# Read-only with standard filters (ids/updated_since/limit/offset) plus the
# resource's declared equality filters.
class McpToolkit::ResourceSchema
  TYPE_FORMATS = {
    datetime: "ISO 8601",
    date: "ISO 8601",
    decimal: "number",
    float: "number",
    integer: "integer",
    boolean: "true/false",
    string: "string",
    text: "string"
  }.freeze
  COMPUTED_TYPE = "computed"
  STANDARD_FILTERS = %w[ids updated_since limit offset].freeze

  def self.call(resource)
    new(resource).call
  end

  def initialize(resource)
    @resource = resource
    @model = resource.model
  end

  def call
    {
      name: resource.name,
      description: resource.description,
      attributes:,
      relationships:,
      standard_filters: STANDARD_FILTERS,
      filters:
    }
  end

  private

  attr_reader :resource, :model

  def attributes
    resource.attribute_names.map { |name| attribute_schema(name) }
  end

  def attribute_schema(name)
    type = column_type(name)
    {
      name:,
      type: type ? type.to_s : COMPUTED_TYPE,
      format: type ? TYPE_FORMATS[type] : nil,
      filterable: filterable_column_for(name).present?
    }.compact
  end

  # Per-attribute equality filters this resource accepts on the `list` tool's
  # `filter` argument. Each entry is the request-facing key, the backing column
  # it matches against, and the column's type — self-describing so an MCP client
  # can construct a valid filter without trial and error.
  def filters
    resource.filterable_columns.sort.map do |request_key, column|
      type = column_type(column)
      {
        key: request_key,
        column:,
        type: type ? type.to_s : COMPUTED_TYPE,
        format: type ? TYPE_FORMATS[type] : nil
      }.compact
    end
  end

  # Backing column for a serialized attribute that is also a filter key, if any.
  # A filter key may be a public alias (e.g. booking_id -> synced_booking_id) so
  # we match on either the request key or the column.
  def filterable_column_for(attribute_name)
    resource.filterable_columns.find do |request_key, column|
      request_key.to_s == attribute_name.to_s || column.to_s == attribute_name.to_s
    end
  end

  def relationships
    resource.association_descriptors.map do |association|
      {
        name: association.links_key,
        kind: association.type.to_s,
        polymorphic: association.polymorphic || false
      }
    end
  end

  # Reads an attribute's DB column type, tolerating models that don't expose
  # `columns_hash` (returns nil => the attribute is reported as "computed").
  def column_type(name)
    return nil unless model.respond_to?(:columns_hash)

    model.columns_hash[name.to_s]&.type
  end
end
