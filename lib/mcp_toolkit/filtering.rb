# frozen_string_literal: true

# Applies the `list` tool's `filter` params to an already-scoped relation, with
# the following semantics:
#
#   * a BARE value filters by equality:               filter: { booking_id: 42 }
#     - a comma-separated string becomes an IN lookup: filter: { status: "a,b" }
#     - an Array of scalars becomes an IN lookup too:  filter: { status: ["a", "b"] }
#     - the string "null" (or a JSON null) matches NULL rows: filter: { canceled_at: "null" }
#   * an { op:, value: } HASH filters with an operator: filter: { price: { op: "gteq", value: 100 } }
#   * an ARRAY of those hashes ANDs them (ranges):
#       filter: { price: [{ op: "gteq", value: 100 }, { op: "lt", value: 200 }] }
#
# Supported operators (validated against the column's DB type):
#   eq, not_eq, gt, gteq, lt, lteq        — numeric / datetime columns
#   eq, not_eq, in, matches, does_not_match — string columns (matches => case-insensitive LIKE)
#   eq, not_eq                            — boolean columns
#
# Allowlist-safe: only the resource's declared `filterable` keys may be filtered,
# each resolved to its backing column. Unknown keys are rejected upstream by the
# ListExecutor, and an operator unsupported for a column's type raises
# InvalidParams — there is no arbitrary column or SQL injection surface.
module McpToolkit::Filtering
  OPERATORS_BY_TYPE = {
    integer: %w[eq not_eq gt gteq lt lteq].freeze,
    float: %w[eq not_eq gt gteq lt lteq].freeze,
    decimal: %w[eq not_eq gt gteq lt lteq].freeze,
    datetime: %w[eq not_eq gt gteq lt lteq].freeze,
    date: %w[eq not_eq gt gteq lt lteq].freeze,
    string: %w[eq not_eq in matches does_not_match].freeze,
    text: %w[eq not_eq in matches does_not_match].freeze,
    boolean: %w[eq not_eq].freeze
  }.freeze

  # Operators that map straight onto an Arel predication method.
  AREL_PREDICATIONS = %w[eq not_eq gt gteq lt lteq in matches does_not_match].freeze

  NULL_TOKEN = "null"

  # @param relation the already account-scoped relation
  # @param column [Symbol] the backing DB column (already resolved from the allowlist)
  # @param value the filter value: a bare value, an { op:, value: } hash, or an
  #   array of such hashes
  # @param config [McpToolkit::Configuration] supplies the SQL sanitizer used to
  #   escape LIKE wildcards
  # @return the relation with the filter(s) applied
  def self.apply(relation, column, value, config: McpToolkit.config)
    if compound?(value)
      apply_condition(relation, column, value, config:)
    elsif collection?(value)
      value.inject(relation) { |rel, condition| apply_condition(rel, column, condition, config:) }
    elsif mixed_collection?(value)
      raise McpToolkit::Errors::InvalidParams,
            "a filter array must contain either only { op:, value: } conditions or only bare values"
    else
      # Bare value(s): equality. A comma-separated string or an Array of scalars
      # becomes an IN lookup, matching the implicit `eq` semantics; "null" / a
      # JSON null matches NULL rows.
      relation.where(column => equality_value(value))
    end
  end

  # A single operator-based condition, e.g. { op: "gt", value: 1000 }.
  def self.compound?(value)
    condition_hash?(value) && (value.key?(:op) || value.key?("op"))
  end

  # Several operator-based conditions on one attribute, ANDed (ranges).
  def self.collection?(value)
    value.is_a?(Array) && value.any? && value.all? { |element| compound?(element) }
  end

  # An Array mixing operator conditions with bare values — rejected explicitly:
  # neither the AND-of-conditions nor the IN-set reading fits, and treating it as
  # either would silently match the wrong rows.
  def self.mixed_collection?(value)
    value.is_a?(Array) && value.any? { |element| compound?(element) }
  end

  def self.condition_hash?(value)
    value.is_a?(Hash)
  end

  def self.apply_condition(relation, column, condition, config:)
    operator = fetch(condition, :op).to_s
    raise McpToolkit::Errors::InvalidParams, "a filter operator is required" if operator.empty?

    type = column_type(relation, column)
    validate_operator!(operator, type, column)

    raw = fetch(condition, :value)
    relation.where(predicate_for(relation, column, operator, raw, config:))
  end

  # Reads a key regardless of symbol/string keys; checks presence (not
  # truthiness) so a literal `false` / `nil` value survives.
  def self.fetch(condition, key)
    return condition[key] if condition.key?(key)

    condition[key.to_s] if condition.key?(key.to_s)
  end

  def self.column_type(relation, column)
    model = relation.respond_to?(:model) ? relation.model : nil
    return nil unless model.respond_to?(:columns_hash)

    model.columns_hash[column.to_s]&.type
  end

  def self.validate_operator!(operator, type, column)
    allowed = OPERATORS_BY_TYPE[type]
    if allowed.nil?
      raise McpToolkit::Errors::InvalidParams,
            "'#{column}' cannot be filtered with operators"
    end
    return if allowed.include?(operator)

    raise McpToolkit::Errors::InvalidParams,
          "'#{operator}' operator is not supported for #{column} (#{type}). " \
          "Supported operators: #{allowed.join(", ")}."
  end

  # Builds the predicate to hand to `relation.where`. For a real ActiveRecord
  # relation we build an Arel node (so it composes with the scope safely and is
  # immune to SQL injection); a relation without an `arel_table` (the in-memory
  # test fake) receives a portable Predicate value object it knows how to apply.
  def self.predicate_for(relation, column, operator, raw, config:)
    value = normalize_value(operator, raw, config:)

    model = relation.respond_to?(:model) ? relation.model : nil
    if model.respond_to?(:arel_table)
      model.arel_table[column.to_sym].public_send(arel_operator(operator, value), value)
    else
      Predicate.new(column.to_sym, arel_operator(operator, value), value)
    end
  end

  # `eq` fans out to an IN lookup (normalize_value turns its value into a set) —
  # EXCEPT against NULL: Arel renders `in(nil)` as `IN (NULL)`, which matches no
  # rows in SQL, so eq/in with a nil value stay/become `eq` (rendered `IS NULL`).
  def self.arel_operator(operator, value)
    return operator unless %w[eq in].include?(operator)

    value.nil? ? "eq" : "in"
  end

  # `eq` / `in` against a (possibly comma-separated string or Array) value
  # becomes an IN set. `matches` / `does_not_match` wrap the value in `%...%`
  # with LIKE wildcards escaped so they match literally. `null` / a JSON null
  # => nil for every operator.
  def self.normalize_value(operator, raw, config:)
    return nil if raw.nil? || raw.to_s == NULL_TOKEN

    case operator
    when "eq", "in"
      resolved = equality_value(raw)
      resolved.is_a?(Array) ? resolved : [resolved]
    when "matches", "does_not_match"
      "%#{config.sql_sanitizer.sanitize_sql_like(raw.to_s)}%"
    else
      raw
    end
  end

  # A bare (non-operator) filter value resolved for equality: `"null"` / nil =>
  # nil (matches NULL rows); a comma-separated string => its parts (IN); an
  # Array => an IN set, each element resolved the same way with comma-splits
  # flattened in.
  def self.equality_value(value)
    if value.is_a?(Array)
      return value.flat_map do |element|
        resolved = equality_value(element)
        resolved.is_a?(Array) ? resolved : [resolved]
      end
    end
    return nil if value.to_s == NULL_TOKEN

    str = value.to_s
    str.include?(",") ? str.split(",") : value
  end

  # Portable representation of an operator predicate, applied by the in-memory
  # test relation. Production uses Arel nodes instead (see .predicate_for).
  Predicate = Struct.new(:column, :operator, :value)
end
