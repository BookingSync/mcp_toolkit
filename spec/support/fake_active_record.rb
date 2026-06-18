# frozen_string_literal: true

# Minimal in-memory stand-ins that quack like the slice of ActiveRecord the
# executors and serializer touch — enough to exercise the registry -> executor ->
# serializer path without a database. NOT a general AR fake; it implements only
# the methods the toolkit calls (`where`, `order`, `offset`, `limit`, `count`,
# `to_a`, `find_by`, `table_name`, and `columns_hash` / `model_name` on the class).

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

  attr_reader :table_name

  def initialize(rows, table_name: "records", columns: {})
    @rows = rows
    @table_name = table_name
    @columns = columns
  end

  def where(conditions)
    filtered = @rows.select do |row|
      conditions.all? do |column, value|
        actual = row[column]
        if value.is_a?(Array)
          value.map(&:to_s).include?(actual.to_s)
        else
          actual.to_s == value.to_s
        end
      end
    end
    with_rows(filtered)
  end

  def order(_column)
    with_rows(@rows.sort_by(&:id))
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

  def with_rows(rows)
    self.class.new(rows, table_name: @table_name, columns: @columns)
  end
end

# A fake model class: holds a relation factory + column metadata + a model_name.
class FakeModelName
  def initialize(plural)
    @plural = plural
  end

  attr_reader :plural
end
