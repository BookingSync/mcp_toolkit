# frozen_string_literal: true

# Applies the `list` tool's `filter` params to an already-scoped relation, with
# the following semantics:
#
#   * a BARE value filters by equality:               filter: { booking_id: 42 }
#     - a comma-separated string becomes an IN lookup: filter: { status: "a,b" }
#     - an Array of scalars becomes an IN lookup too:  filter: { status: ["a", "b"] }
#     - the string "null" (or a JSON null) matches NULL rows: filter: { canceled_at: "null" }
#       (as a SCALAR value only — inside an IN set, elements must be non-null
#       scalars and "null" stays a literal string, because SQL `IN` cannot match
#       NULL; a null-or-nothing condition is expressed as a scalar filter)
#   * an { op:, value: } HASH filters with an operator: filter: { price: { op: "gteq", value: 100 } }
#   * an ARRAY of those hashes ANDs them (ranges):
#       filter: { price: [{ op: "gteq", value: 100 }, { op: "lt", value: 200 }] }
#
# Supported operators (validated against the column's DB type):
#   eq, not_eq, gt, gteq, lt, lteq        — numeric / datetime columns (+ in for date)
#   eq, not_eq, in, matches, does_not_match — string columns (matches => case-insensitive LIKE)
#   eq, not_eq                            — boolean columns
#   eq, in                                — any other column type (uuid, enum, jsonb, ...)
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
    date: %w[eq not_eq gt gteq lt lteq in].freeze,
    string: %w[eq in not_eq matches does_not_match].freeze,
    text: %w[eq in not_eq matches does_not_match].freeze,
    boolean: %w[eq not_eq].freeze
  }.freeze

  # Operators for a column type OUTSIDE the table above (uuid, enum, jsonb,
  # citext, ...): plain equality/IN still work on any column, so they stay
  # available rather than turning "cannot be filtered with operators" — which
  # also matches the API contract this replaces for adopting hosts.
  DEFAULT_OPERATORS = %w[eq in].freeze

  # Operators that map straight onto an Arel predication method.
  AREL_PREDICATIONS = %w[eq not_eq gt gteq lt lteq in matches does_not_match].freeze

  NULL_TOKEN = "null"

  # Operators for which a null value is meaningful: eq/in render `IS NULL`,
  # not_eq renders `IS NOT NULL`. Every other operator rejects null explicitly —
  # a comparison or LIKE against NULL can never match a row in SQL, so passing
  # one through silently would return a wrong (empty) result.
  NULL_ACCEPTING_OPERATORS = %w[eq in not_eq].freeze

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
      enforce_filter_limit!(value.length, config)
      value.inject(relation) { |rel, condition| apply_condition(rel, column, condition, config:) }
    elsif mixed_collection?(value)
      raise McpToolkit::Errors::InvalidParams,
            "a filter array must contain either only { op:, value: } conditions or only bare values"
    else
      # Bare value(s): equality. Under the default :tokenized semantics a
      # comma-separated string or an Array of scalars becomes an IN lookup and
      # "null" / a JSON null matches NULL rows; under :literal the value is
      # handed to the WHERE clause verbatim (see
      # Configuration#bare_filter_value_semantics).
      relation.where(column => bare_value(value, config))
    end
  end

  def self.bare_value(value, config)
    if value.is_a?(Hash)
      raise McpToolkit::Errors::InvalidParams,
            "unsupported filter value; use a bare scalar, an array of scalars, " \
            "or { op:, value: } condition(s)"
    end

    # An Array bare value renders as `WHERE column IN (...)` under EITHER
    # semantics, so bound its size before the branch below. The :literal path
    # returns the array verbatim and would otherwise skip the limit that
    # equality_value/equality_value_set enforce only on the :tokenized path —
    # defeating the query-complexity guard on the new host-compatibility path.
    enforce_filter_limit!(value.length, config) if value.is_a?(Array)

    return value if config.bare_filter_value_semantics == :literal

    equality_value(value, config:)
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
    validate_operator!(operator, type, column, config:)

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

  # Operators an attribute of the given column type accepts — the single source
  # for both the schema's advertisement and the executor's enforcement, so the
  # two can never disagree. `[]` for an attribute with no backing column (which
  # cannot be filtered with operators). A host can override sets per type via
  # config.filter_operator_overrides (e.g. to preserve a pre-gem contract).
  def self.operators_for(type, config: McpToolkit.config)
    return [] if type.nil?

    config.filter_operator_overrides.fetch(type) { OPERATORS_BY_TYPE.fetch(type, DEFAULT_OPERATORS) }
  end

  def self.validate_operator!(operator, type, column, config:)
    if type.nil?
      raise McpToolkit::Errors::InvalidParams,
            "'#{column}' cannot be filtered with operators"
    end

    allowed = operators_for(type, config:)
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
    method = arel_operator(operator, value)

    # Defense in depth: only a known-safe Arel predication may ever reach
    # public_send. operators_for/validate_operator! already gate this and
    # config.filter_operator_overrides is validated at assignment — but the
    # value handed to any operator outside eq/in/matches is passed through
    # VERBATIM (normalize_value's else branch), so an operator that slipped in
    # (e.g. a host-configured "extract") must never be dispatched: Arel would
    # interpolate the request value as raw SQL. This is the last guard before
    # the metaprogramming call.
    unless AREL_PREDICATIONS.include?(method)
      raise McpToolkit::Errors::InvalidParams, "'#{operator}' is not a supported filter operator"
    end

    model = relation.respond_to?(:model) ? relation.model : nil
    if model.respond_to?(:arel_table)
      model.arel_table[column.to_sym].public_send(method, value)
    else
      Predicate.new(column.to_sym, method, value)
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
  # => nil for the NULL_ACCEPTING_OPERATORS, rejected for every other operator.
  def self.normalize_value(operator, raw, config:)
    if raw.nil? || raw.to_s == NULL_TOKEN
      unless NULL_ACCEPTING_OPERATORS.include?(operator)
        raise McpToolkit::Errors::InvalidParams,
              "'#{operator}' does not accept a null value " \
              "(only #{NULL_ACCEPTING_OPERATORS.join("/")} do)"
      end
      return nil
    end

    case operator
    when "eq", "in"
      resolved = equality_value(raw, config:)
      resolved.is_a?(Array) ? resolved : [resolved]
    when "matches", "does_not_match"
      "%#{config.sql_sanitizer.sanitize_sql_like(raw.to_s)}%"
    else
      raw
    end
  end

  # A bare (non-operator) filter value resolved for equality: `"null"` / nil =>
  # nil (matches NULL rows); a comma-separated string => its parts (IN); an
  # Array => an IN set of non-null scalars (see .equality_value_set). Any other
  # non-scalar (an op-less Hash) is rejected — passed through it would reach the
  # database as a malformed condition.
  def self.equality_value(value, config: McpToolkit.config)
    return equality_value_set(value, config:) if value.is_a?(Array)
    return nil if value.nil? || value.to_s == NULL_TOKEN

    if value.is_a?(Hash)
      raise McpToolkit::Errors::InvalidParams,
            "unsupported filter value; use a bare scalar, an array of scalars, " \
            "or { op:, value: } condition(s)"
    end

    str = value.to_s
    return value unless str.include?(",")

    parts = str.split(",")
    enforce_filter_limit!(parts.length, config)
    parts
  end

  # Resolves an Array filter value into a flat IN set. Elements must be non-null
  # scalars (comma-separated strings are split in); nil / nested Array / Hash
  # elements are rejected explicitly — SQL `IN` cannot match NULL (Arel renders
  # a nil element as the never-matching `IN (..., NULL)`), and a non-scalar
  # element is a malformed condition either way. The `"null"` token is NOT
  # resolved inside a set for the same reason: it stays a literal string, and a
  # null-or-nothing condition is expressed as a scalar filter value instead.
  def self.equality_value_set(values, config: McpToolkit.config)
    resolved = values.flat_map do |element|
      if element.nil? || element.is_a?(Array) || element.is_a?(Hash)
        raise McpToolkit::Errors::InvalidParams,
              "an IN-set filter must contain only non-null scalar values; " \
              "to match NULL rows pass \"null\" as the filter's single value"
      end

      str = element.to_s
      str.include?(",") ? str.split(",") : [element]
    end
    enforce_filter_limit!(resolved.length, config)
    resolved
  end

  # Bounds how many values an IN-set resolves to (and how many operator
  # conditions may be ANDed on one attribute, enforced by .apply), so a valid
  # token can't emit an unbounded IN clause / AND-chain — oversized SQL + Arel
  # AST and expensive query planning, which matters because rate limiting is
  # opt-in (config.rate_limit_max_requests). Disabled when
  # config.max_filter_values is nil.
  def self.enforce_filter_limit!(count, config)
    max = config.max_filter_values
    return if max.nil? || count <= max

    raise McpToolkit::Errors::InvalidParams,
          "a filter may carry at most #{max} values or conditions (got #{count})"
  end

  # Portable representation of an operator predicate, applied by the in-memory
  # test relation. Production uses Arel nodes instead (see .predicate_for).
  Predicate = Struct.new(:column, :operator, :value)
end
