# frozen_string_literal: true

# Applies the `list` tool's `filter` params to an already-scoped relation,
# matching BookingSync's API v3 filtering semantics:
#
#   * a BARE value filters by equality:               filter: { booking_id: 42 }
#     (a comma-separated string becomes an IN lookup:  filter: { status: "a,b" })
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

  module_function

  # @param relation the already account-scoped relation
  # @param column [Symbol] the backing DB column (already resolved from the allowlist)
  # @param value the filter value: a bare value, an { op:, value: } hash, or an
  #   array of such hashes
  # @return the relation with the filter(s) applied
  def apply(relation, column, value)
    if compound?(value)
      apply_condition(relation, column, value)
    elsif collection?(value)
      value.inject(relation) { |rel, condition| apply_condition(rel, column, condition) }
    else
      # Bare value: equality. A comma-separated string becomes an IN lookup,
      # matching API v3's implicit `eq`.
      relation.where(column => equality_value(value))
    end
  end

  # A single operator-based condition, e.g. { op: "gt", value: 1000 }.
  def compound?(value)
    condition_hash?(value) && (value.key?(:op) || value.key?("op"))
  end

  # Several operator-based conditions on one attribute, ANDed (ranges).
  def collection?(value)
    value.is_a?(Array) && value.any? && value.all? { |element| compound?(element) }
  end

  def condition_hash?(value)
    value.is_a?(Hash)
  end

  def apply_condition(relation, column, condition)
    operator = fetch(condition, :op).to_s
    raise McpToolkit::Errors::InvalidParams, "a filter operator is required" if operator.empty?

    type = column_type(relation, column)
    validate_operator!(operator, type, column)

    raw = fetch(condition, :value)
    relation.where(predicate_for(relation, column, operator, raw))
  end

  # Reads a key regardless of symbol/string keys; checks presence (not
  # truthiness) so a literal `false` / `nil` value survives.
  def fetch(condition, key)
    return condition[key] if condition.key?(key)

    condition[key.to_s] if condition.key?(key.to_s)
  end

  def column_type(relation, column)
    model = relation.respond_to?(:model) ? relation.model : nil
    return nil unless model.respond_to?(:columns_hash)

    model.columns_hash[column.to_s]&.type
  end

  def validate_operator!(operator, type, column)
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
  def predicate_for(relation, column, operator, raw)
    value = normalize_value(operator, raw)
    arel_operator = operator == "eq" ? "in" : operator

    model = relation.respond_to?(:model) ? relation.model : nil
    if model.respond_to?(:arel_table)
      model.arel_table[column.to_sym].public_send(arel_operator, value)
    else
      Predicate.new(column.to_sym, arel_operator, value)
    end
  end

  # `eq` against a (possibly comma-separated) value becomes an IN set, matching
  # API v3. `matches` / `does_not_match` wrap the value in `%...%` with LIKE
  # wildcards escaped so they match literally. `null` => nil for every operator.
  def normalize_value(operator, raw)
    return nil if raw.to_s == NULL_TOKEN

    case operator
    when "eq", "in"
      raw.to_s.split(",")
    when "matches", "does_not_match"
      "%#{sanitize_like(raw.to_s)}%"
    else
      raw
    end
  end

  def equality_value(value)
    return nil if value.to_s == NULL_TOKEN

    str = value.to_s
    str.include?(",") ? str.split(",") : value
  end

  # Escapes LIKE wildcards. Uses ActiveRecord's sanitizer when available
  # (production), falling back to a manual escape for the DB-free test fake.
  def sanitize_like(string)
    if defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:sanitize_sql_like)
      ActiveRecord::Base.sanitize_sql_like(string)
    else
      string.gsub(/([\\%_])/, '\\\\\1')
    end
  end

  # Portable representation of an operator predicate, applied by the in-memory
  # test relation. Production uses Arel nodes instead (see #predicate_for).
  Predicate = Struct.new(:column, :operator, :value)
end
