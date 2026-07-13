# frozen_string_literal: true

# Runs a read-only, paginated "list" query for a registered resource, rooted on
# the scoped relation. Supports the standard `ids`, `updated_since`, `limit`,
# `offset` filters plus the resource's declared per-attribute filters (equality
# AND operator-based — see McpToolkit::Filtering), and serializes via the
# resource's serializer, producing the `{ <root> => [...], meta: {...} }` wrapper.
# An optional `fields` param applies a sparse fieldset to each row (see
# McpToolkit::FieldSelection).
class McpToolkit::ListExecutor
  DEFAULT_LIMIT = 25
  MAX_LIMIT = 100
  # Column types whose primary key sorts naturally by `id`. Anything else (e.g. a
  # string/uuid PK) sorts by `created_at` instead.
  NUMERIC_PK_TYPES = %i[integer bigint].freeze

  def self.call(resource:, scope_root:, params:)
    new(resource:, scope_root:, params:).call
  end

  def initialize(resource:, scope_root:, params:)
    @resource = resource
    @scope_root = scope_root
    @params = (params || {}).deep_symbolize_keys
  end

  def call
    # Validate the sparse fieldset BEFORE running the query so a bad `fields`
    # fails fast rather than after a needless count + fetch.
    selection = McpToolkit::FieldSelection.build(resource:, raw: params[:fields])
    relation = build_relation
    total_count = relation.count
    rows = paginate(relation).to_a

    McpToolkit::Serialization.new(resource.serializer, selection).collection(
      rows, scope: scope_root, total_count:, limit:, offset:
    )
  end

  private

  attr_reader :resource, :scope_root, :params

  def build_relation
    relation = resource.resolve_relation(scope_root)
    relation = apply_ids(relation)
    relation = apply_updated_since(relation)
    relation = apply_custom_filters(relation)
    relation = apply_attribute_filters(relation)
    apply_order(relation)
  end

  # Applies the resource's declared custom (resource-specific) filters — each an
  # arbitrary host-supplied block — for the keys actually present as TOP-LEVEL
  # request params, BEFORE the generic allowlist `filter` attributes. Each block
  # receives the already-scoped relation and the raw value and returns a narrowed
  # relation, so a host can express a relational filter the generic path can't
  # derive (see Resource#filter). A resource with no custom filters is a no-op.
  def apply_custom_filters(relation)
    resource.custom_filters.each_value do |custom_filter|
      value = params[custom_filter.name]
      next if value.nil? || value == ""

      relation = custom_filter.applier.call(relation, value)
    end
    relation
  end

  # Order by `id` when the primary key is numeric; otherwise per
  # `config.non_numeric_pk_order`: `created_at` with the primary key as a
  # tiebreaker (default — rows bulk-inserted in one transaction share a
  # `created_at`, and without a total order offset pagination could duplicate
  # or skip rows), or the primary key alone for a host preserving a pre-gem
  # order-by-id contract. `numeric_primary_key?` returning false guarantees the
  # model exposes a non-nil primary key, so it can be read directly here.
  def apply_order(relation)
    return relation.order(:id) if numeric_primary_key?

    pk = resource.model.primary_key.to_sym
    return relation.order(pk) if McpToolkit.config.non_numeric_pk_order == :primary_key

    relation.order(:created_at, pk)
  end

  def numeric_primary_key?
    model = resource.model
    return true unless model.respond_to?(:columns_hash) && model.respond_to?(:primary_key)

    pk = model.primary_key
    return true if pk.nil?

    type = model.columns_hash[pk.to_s]&.type
    type.nil? || NUMERIC_PK_TYPES.include?(type)
  end

  # Applies per-attribute filters (`filter: { key: value | { op:, value: } | [...] }`).
  # Each request-facing key is resolved against the resource's declared allowlist
  # (`Resource#filterable`) to its backing column, then added as WHERE clause(s) on
  # TOP of the already scoped relation — filtering composes with scoping and can
  # only ever NARROW it, never widen it. Equality and operator-based semantics are
  # delegated to McpToolkit::Filtering.
  #
  # Unknown filter keys are rejected with InvalidParams, so the caller gets
  # actionable feedback instead of a silently-ignored filter.
  def apply_attribute_filters(relation)
    filter = params[:filter]
    return relation if filter.blank?

    mapping = resource.filterable_columns
    validate_filter_keys!(filter, mapping)
    validate_filter_companions!(filter)

    literal = McpToolkit.config.bare_filter_value_semantics == :literal
    filter.each do |request_key, value|
      # Under :tokenized semantics an empty string means "no filter" (a JSON
      # null still flows through as an IS NULL filter, like the "null" token —
      # see McpToolkit::Filtering); under :literal every value reaches the
      # WHERE clause verbatim.
      next if value == "" && !literal

      column = mapping[request_key.to_sym]
      relation = McpToolkit::Filtering.apply(relation, column, value)
    end
    relation
  end

  # A filter key may declare a companion key it cannot be used without (e.g. a
  # polymorphic foreign key is type-ambiguous without its `*_type`) — see
  # Resource#filter_requirements. Rejected up front rather than producing a
  # subtly wrong WHERE.
  def validate_filter_companions!(filter)
    requirements = resource.filter_requirements
    return if requirements.empty?

    keys = filter.keys.map(&:to_sym)
    requirements.each do |key, required|
      next unless keys.include?(key)
      next if keys.include?(required)

      raise McpToolkit::Errors::InvalidParams,
            "filter attribute #{key} requires #{required} to also be provided"
    end
  end

  def validate_filter_keys!(filter, mapping)
    keys = filter.keys.map(&:to_sym)
    unknown = keys - mapping.keys
    return if unknown.empty?

    allowed = mapping.keys.sort.join(", ")
    raise McpToolkit::Errors::InvalidParams,
          "unknown filter attribute(s): #{unknown.join(", ")}. " \
          "Filterable attributes for this resource: #{allowed.presence || "(none)"}"
  end

  def apply_ids(relation)
    return relation if params[:ids].blank?

    ids = params[:ids].to_s.split(",").map(&:strip).compact_blank
    ids.empty? ? relation : relation.where(id: ids)
  end

  def apply_updated_since(relation)
    return relation if params[:updated_since].blank?

    time = parse_time(params[:updated_since])
    relation.where("#{relation.table_name}.updated_at > ?", time)
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) || raise(ArgumentError)
  rescue ArgumentError, TypeError
    raise McpToolkit::Errors::InvalidParams, "updated_since must be an ISO 8601 timestamp"
  end

  def paginate(relation)
    relation.offset(offset).limit(limit)
  end

  def limit
    raw = params[:limit] || DEFAULT_LIMIT
    [[raw.to_i, 1].max, MAX_LIMIT].min # rubocop:disable Style/ComparableClamp
  end

  def offset
    [params[:offset].to_i, 0].max
  end
end
