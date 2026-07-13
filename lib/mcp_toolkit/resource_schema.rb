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
      resource_filters:,
      standard_filters: STANDARD_FILTERS,
      sparse_fieldsets: true,
      filter_examples:,
      filters:
    }.compact
  end

  private

  attr_reader :resource, :model, :registry

  def attributes
    @attributes ||= resource.attribute_names.map { |name| attribute_schema(name) }
  end

  def attribute_schema(name)
    type = column_type(name)
    {
      name:,
      type: type ? type.to_s : COMPUTED_TYPE,
      format: type ? TYPE_FORMATS[type] : nil,
      filterable: filterable_column_for(name).present?,
      operators: operators_for(name)
    }
  end

  # The filter operators an attribute accepts, derived from the backing column's
  # type via McpToolkit::Filtering.operators_for. `[]` for a non-filterable
  # attribute (or one with no backing column) — self-describing so a client
  # knows exactly which `{ op:, value: }` conditions `list` will accept.
  def operators_for(attribute_name)
    pair = filterable_column_for(attribute_name)
    return [] unless pair

    McpToolkit::Filtering.operators_for(column_type(pair.last))
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
  # Entries keep nil type/description keys (rather than compacting) — the
  # pre-gem contract emitted them, and an always-present shape is easier for a
  # client to consume.
  def resource_filters
    resource.custom_filters.each_value.map do |custom_filter|
      {
        name: custom_filter.name.to_s,
        type: custom_filter.type&.to_s,
        description: custom_filter.description
      }
    end
  end

  # Ready-to-use `filter` payload examples built from this resource's own
  # filterable attributes and relationships, so a client can copy a working
  # shape instead of deriving it from the operator lists.
  def filter_examples
    [equality_example, comparison_example, range_example, relationship_example].compact
  end

  def equality_example
    attribute = example_attributes.find { |candidate| candidate[:type] == "string" } || example_attributes.first
    return unless attribute

    { attribute[:name] => sample_value(attribute[:type]) }
  end

  def comparison_example
    attribute = comparison_attribute
    return unless attribute

    { attribute[:name] => { op: "gt", value: sample_value(attribute[:type]) } }
  end

  def range_example
    attribute = comparison_attribute
    return unless attribute

    {
      attribute[:name] => [
        { op: "gteq", value: sample_value(attribute[:type]) },
        { op: "lt", value: sample_value(attribute[:type]) }
      ]
    }
  end

  def relationship_example
    relationship = relationships.find { |candidate| candidate[:filter] }
    return unless relationship

    example = { relationship[:filter][:keys].first => 1 }
    example[relationship[:filter][:requires]] = "User" if relationship[:filter][:requires]
    example
  end

  def filterable_attributes
    attributes.select { |attribute| attribute[:filterable] }
  end

  # `id` is filterable but uninteresting as an example (use the `ids` filter for that).
  def example_attributes
    filterable_attributes.reject { |attribute| attribute[:name] == :id }
  end

  def comparison_attribute
    example_attributes.find { |attribute| attribute[:operators].include?("gt") }
  end

  def sample_value(type)
    case type.to_s
    when "integer" then 1
    when "decimal", "float" then "100.0"
    when "boolean" then true
    when "datetime", "date" then "2026-01-01T00:00:00Z"
    else "..."
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
    @relationships ||= resource.association_descriptors.map { |association| relationship_schema(association) }
  end

  # One relationship entry: the link key/kind/polymorphic flag, the registered
  # resource the link resolves to — emitted BOTH as `resource` (nullable) and,
  # when resolved, as `target_resource` (so e.g. a
  # `scheduled_notifications.notification` link is discoverably the
  # `notifications` resource rather than a name to guess) — and, when the
  # link's foreign key is filterable, a `filter` block telling a client HOW to
  # filter by the relationship (see #relationship_filter).
  def relationship_schema(association)
    target = target_resource_for(association)
    schema = {
      name: association.links_key,
      kind: association.type.to_s,
      polymorphic: association.polymorphic || false,
      resource: target&.name,
      filter: relationship_filter(association.links_key)
    }
    schema[:target_resource] = target.name if target
    schema
  end

  # How to filter by a relationship, when its foreign key is in the filter
  # allowlist: the accepted request keys (the FK, plus the bare link name when
  # aliased), the backing column's type, its operators, and — for a key that
  # cannot be used alone (e.g. a polymorphic FK needing its `*_type`) — the
  # companion key it `requires` (see Resource#filter_requirements).
  def relationship_filter(name)
    id_key = :"#{name}_id"
    column = resource.filterable_columns[id_key]
    return nil unless column

    keys = [id_key]
    keys << name.to_sym if resource.filterable_columns.key?(name.to_sym)
    {
      keys:,
      type: column_type(column).to_s,
      operators: operators_for(id_key),
      requires: resource.filter_requirements[id_key]
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
