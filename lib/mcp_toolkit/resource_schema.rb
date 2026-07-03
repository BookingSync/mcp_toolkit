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
  # Attribute names, in priority order, treated as a target resource's
  # human-readable label. The first one a target actually serializes is surfaced
  # as a `target_name_attribute` hint on the relationship (best-effort; omitted if
  # the target declares none of them).
  NAME_ATTRIBUTE_CANDIDATES = %i[name title label subject display_name].freeze

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
      attributes:,
      relationships:,
      standard_filters: STANDARD_FILTERS,
      filters:
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
    resource.association_descriptors.map { |association| relationship_schema(association) }
  end

  # One relationship entry. Beyond the link key/kind/polymorphic flag it now also
  # names the `target_resource` — the registered resource this link resolves to,
  # callable via `list`/`get` — so e.g. a `scheduled_notifications.notification`
  # link is discoverably the `notifications` resource rather than a name to guess.
  # `target_name_attribute` is a best-effort hint at that resource's human-readable
  # field. Both are omitted (additive/backward-compatible) when unresolved.
  def relationship_schema(association)
    target = target_resource_for(association)
    {
      name: association.links_key,
      kind: association.type.to_s,
      polymorphic: association.polymorphic || false,
      target_resource: target&.name,
      target_name_attribute: name_attribute_for(target)
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

  def name_attribute_for(target)
    return nil unless target

    names = target.attribute_names
    NAME_ATTRIBUTE_CANDIDATES.find { |candidate| names.include?(candidate) }&.to_s
  end

  # Reads an attribute's DB column type, tolerating models that don't expose
  # `columns_hash` (returns nil => the attribute is reported as "computed").
  def column_type(name)
    return nil unless model.respond_to?(:columns_hash)

    model.columns_hash[name.to_s]&.type
  end
end
