# frozen_string_literal: true

# Minimal in-memory stand-ins that quack like the slice of ActiveRecord the
# executors and serializer touch — enough to exercise the registry -> executor ->
# serializer path without a database. NOT a general AR fake; it implements only
# the methods the toolkit calls (`where`, `order`, `offset`, `limit`, `count`,
# `to_a`, `find_by`, `table_name`, `model`, and `columns_hash` / `model_name` /
# `primary_key` on the class). `where` understands both a `{ column => value }`
# hash and a McpToolkit::Filtering::Predicate (operator-based filtering).

# A struct-like record with arbitrary attributes and an `id`.
class FakeRecord
  def initialize(attrs)
    @attrs = attrs
  end

  def id
    @attrs.fetch(:id)
  end

  def respond_to_missing?(name, _include_private = false)
    @attrs.key?(name.to_sym) || super
  end

  def method_missing(name, *args)
    return @attrs[name] if @attrs.key?(name)

    super
  end

  def [](key)
    @attrs[key.to_sym]
  end
end

# A composable, immutable in-memory relation. Each filtering method returns a new
# relation; `to_a` / `count` materialize.
class FakeRelation
  Column = Struct.new(:type)

  attr_reader :table_name, :model

  def initialize(rows, table_name: "records", model: nil)
    @rows = rows
    @table_name = table_name
    @model = model
  end

  # Accepts either a `{ column => value }` equality hash or a
  # McpToolkit::Filtering::Predicate (operator-based filtering).
  def where(conditions)
    if conditions.is_a?(McpToolkit::Filtering::Predicate)
      with_rows(@rows.select { |row| predicate_match?(row, conditions) })
    else
      filtered = @rows.select do |row|
        conditions.all? { |column, value| equality_match?(row[column], value) }
      end
      with_rows(filtered)
    end
  end

  def order(column)
    with_rows(@rows.sort_by { |row| row[column] })
  end

  def offset(n)
    with_rows(@rows.drop(n.to_i))
  end

  def limit(n)
    with_rows(@rows.take(n.to_i))
  end

  def count
    @rows.size
  end

  def to_a
    @rows
  end

  def find_by(conditions)
    where(conditions).to_a.first
  end

  # has_many serialization reads `pluck(:id)` off the relation.
  def pluck(column)
    @rows.map { |row| row[column] }
  end

  private

  def equality_match?(actual, value)
    if value.is_a?(Array)
      value.map(&:to_s).include?(actual.to_s)
    elsif value.nil?
      actual.nil?
    else
      actual.to_s == value.to_s
    end
  end

  # Applies the operators McpToolkit::Filtering emits (mirroring the Arel
  # predications it builds for real ActiveRecord).
  def predicate_match?(row, predicate)
    actual = row[predicate.column]
    value = predicate.value

    case predicate.operator
    when "in" then Array(value).map(&:to_s).include?(actual.to_s)
    when "not_eq" then actual.to_s != value.to_s
    when "gt" then actual > value
    when "gteq" then actual >= value
    when "lt" then actual < value
    when "lteq" then actual <= value
    when "matches" then like_match?(actual, value)
    when "does_not_match" then !like_match?(actual, value)
    else actual.to_s == value.to_s # "eq" fallback
    end
  end

  # Translates a `%escaped%` LIKE pattern into a case-insensitive substring test.
  def like_match?(actual, pattern)
    inner = pattern.to_s.gsub(/\A%|%\z/, "").gsub(/\\([\\%_])/, '\1')
    actual.to_s.downcase.include?(inner.downcase)
  end

  def with_rows(rows)
    self.class.new(rows, table_name: @table_name, model: @model)
  end
end

# A fake model class: holds a relation factory + column metadata + a model_name.
class FakeModelName
  def initialize(plural)
    @plural = plural
  end

  attr_reader :plural
end
