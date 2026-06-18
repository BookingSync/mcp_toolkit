# frozen_string_literal: true

module McpToolkit
  # Runs a read-only, paginated "list" query for a registered resource, rooted on
  # the scoped relation. Supports the standard `ids`, `updated_since`, `limit`,
  # `offset` filters plus the resource's declared per-attribute equality filters,
  # and serializes via the resource's serializer, producing the
  # `{ <root> => [...], meta: {...} }` wrapper. Extracted from bsa-notifications'
  # `McpServer::ListExecutor`.
  class ListExecutor
    DEFAULT_LIMIT = 25
    MAX_LIMIT = 100

    def self.call(resource:, scope_root:, params:)
      new(resource:, scope_root:, params:).call
    end

    def initialize(resource:, scope_root:, params:)
      @resource = resource
      @scope_root = scope_root
      @params = (params || {}).deep_symbolize_keys
    end

    def call
      relation = build_relation
      total_count = relation.count
      rows = paginate(relation).to_a

      @resource.serializer.serialize_collection(
        rows, scope: @scope_root, total_count:, limit:, offset:
      )
    end

    private

    def build_relation
      relation = @resource.resolve_relation(@scope_root)
      relation = apply_ids(relation)
      relation = apply_updated_since(relation)
      relation = apply_attribute_filters(relation)
      relation.order(:id)
    end

    # Applies per-attribute exact-match equality filters (`filter: { key: value }`).
    # Each request-facing key is resolved against the resource's declared allowlist
    # (`Resource#filterable`) to its backing column, then added as a WHERE on TOP
    # of the already scoped relation — filtering composes with scoping and can only
    # ever NARROW it, never widen it.
    #
    # Unknown filter keys are rejected with InvalidParams, so the caller gets
    # actionable feedback instead of a silently-ignored filter.
    def apply_attribute_filters(relation)
      filter = @params[:filter]
      return relation if filter.blank?

      mapping = @resource.filterable_columns
      validate_filter_keys!(filter, mapping)

      filter.each do |request_key, value|
        next if value.nil? || value == ""

        column = mapping[request_key.to_sym]
        relation = relation.where(column => value)
      end
      relation
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
      return relation if @params[:ids].blank?

      ids = @params[:ids].to_s.split(",").map(&:strip).compact_blank
      ids.empty? ? relation : relation.where(id: ids)
    end

    def apply_updated_since(relation)
      return relation if @params[:updated_since].blank?

      time = parse_time(@params[:updated_since])
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
      raw = @params[:limit] || DEFAULT_LIMIT
      [[raw.to_i, 1].max, MAX_LIMIT].min # rubocop:disable Style/ComparableClamp
    end

    def offset
      [@params[:offset].to_i, 0].max
    end
  end
end
