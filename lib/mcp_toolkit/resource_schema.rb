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

  # `registry` is used to resolve each relationship to the registered resource it
  # points at (see #relationships). Defaults to the process-wide registry; the
  # `resource_schema` tool passes the active config's registry explicitly.
  def self.call(resource, registry: McpToolkit.registry)
    new(resource, registry:).call
  end

  def initialize(resource, registry: McpToolkit.registry)
    @resource = resource
    @model = resource.model
    @registry = registry
  end

  def call
    {
      name: resource.name,
      description: resource.description,
      note: resource.note,
      attributes:,
      relationships:,
      standard_filters: STANDARD_FILTERS,
      filters:,
      resource_filters:
    }
  end

  private

  attr_reader :resource, :model, :registry

  def attributes
    resource.attribute_names.map { |name| attribute_schema(name) }
  end

  def attribute_schema(name)
    type = column_type(name)
    {
      name:,
      type: type ? type.to_s : COMPUTED_TYPE,
      format: type ? TYPE_FORMATS[type] : nil,
      filterable: filterable_column_for(name).present?,
      operators: operators_for(name)
    }.compact
  end

  # The filter operators an attribute accepts, derived from the backing column's
  # type via McpToolkit::Filtering::OPERATORS_BY_TYPE. `[]` for a non-filterable
  # attribute (or one whose column type has no operator set) — self-describing so
  # a client knows exactly which `{ op:, value: }` conditions `list` will accept.
  def operators_for(attribute_name)
    pair = filterable_column_for(attribute_name)
    return [] unless pair

    McpToolkit::Filtering::OPERATORS_BY_TYPE.fetch(column_type(pair.last), [])
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

  # The resource's custom filters (Resource#filter) — resource-specific filters
  # passed as TOP-LEVEL params of the `list` tool (NOT inside `filter`), each
  # applied by a host-supplied block. Surfaced with name/type/description so a
  # client can discover them; `[]` for a resource that declares none.
  def resource_filters
    resource.custom_filters.each_value.map do |custom_filter|
      {
        name: custom_filter.name.to_s,
        type: custom_filter.type.to_s,
        description: custom_filter.description
      }
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
    resource.association_descriptors.map { |association| relationship_schema(association) }
  end

  # One relationship entry. Beyond the link key/kind/polymorphic flag it now also
  # names the `target_resource` — the registered resource this link resolves to,
  # callable via `list`/`get` — so e.g. a `scheduled_notifications.notification`
  # link is discoverably the `notifications` resource rather than a name to guess.
  # It is omitted (additive/backward-compatible) when the target can't be resolved
  # (e.g. a polymorphic link).
  def relationship_schema(association)
    target = target_resource_for(association)
    {
      name: association.links_key,
      kind: association.type.to_s,
      polymorphic: association.polymorphic || false,
      target_resource: target&.name
    }.compact
  end

  # The registered resource an association points at, or nil. Polymorphic links
  # have no single target, so they are left unresolved (the `polymorphic` flag and
  # the record's `{id:, type:}` link value already carry the target type). Prefers
  # an explicit target serializer's model, then falls back to matching the link's
  # (pluralized) name against registered resource names.
  def target_resource_for(association)
    return nil if association.polymorphic

    target_from_serializer(association) || target_from_name(association)
  end

  def target_from_serializer(association)
    serializer = association.serializer
    return nil unless serializer.respond_to?(:model_class)

    target_model = safe_model_class(serializer)
    return nil unless target_model

    registry.resources.find { |candidate| candidate.model == target_model }
  end

  def target_from_name(association)
    candidate_names(association).each do |candidate|
      match = registry.find(candidate)
      return match if match
    end
    nil
  end

  # Names to try against the registry for a link, closest spelling first: the link
  # key and association name as declared, then their pluralizations (resources are
  # registered under plural names, so a singular `notification` link resolves to
  # the `notifications` resource).
  def candidate_names(association)
    [association.links_key, association.name.to_s].flat_map do |base|
      [base, base.pluralize]
    end.uniq
  end

  def safe_model_class(serializer)
    serializer.model_class
  rescue StandardError
    nil
  end

  # Reads an attribute's DB column type, tolerating models that don't expose
  # `columns_hash` (returns nil => the attribute is reported as "computed").
  def column_type(name)
    return nil unless model.respond_to?(:columns_hash)

    model.columns_hash[name.to_s]&.type
  end
end
