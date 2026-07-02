# frozen_string_literal: true

# The DEFAULT serializer base shipped by the toolkit. A self-contained
# implementation of the subset of an AMS-style serializer the MCP wire format
# depends on, with NO dependency on `active_model_serializers` / `fast_jsonapi`.
#
# ## The injection contract
#
# The executors (`ListExecutor` / `GetExecutor`) only ever call two class
# methods on a resource's serializer:
#
#   serializer.serialize_one(record, scope:)
#     # => Hash (a single record's shape), or nil for a nil record
#
#   serializer.serialize_collection(records, scope:, total_count:, limit:, offset:)
#     # => { <root_key> => [ <record_hash>, ... ],
#     #      meta: { total_count:, limit:, offset: } }
#
# ANY class implementing those two methods can be registered as a resource's
# serializer — that is the seam that lets an app's existing serializers slot in
# unchanged alongside this base. The `resource_schema` tool additionally reads
# `declared_attributes` and
# `declared_associations` off the serializer (for shape discovery); a custom
# serializer that wants to power `resource_schema` should expose those too, but
# they are not required for `get` / `list`.
#
# ## Sparse fieldsets (optional)
#
# Both entry points also accept an OPTIONAL `fields:` keyword — an array of the
# attribute and/or relationship link-key names to include (JSON:API's sparse
# fieldset; the two share one flat namespace). `fields: nil` (the default) means
# "everything", so the contract above is unchanged for callers that omit it. When
# a subset is given, only those members are emitted AND only the selected
# relationships are loaded (unselected `has_many` links are never queried). A
# serializer that does NOT declare a `fields:` keyword still supports sparse
# fieldsets — McpToolkit::Serialization prunes its output instead — so honoring
# `fields:` natively is a performance optimization, not a contract requirement.
#
# `scope` is whatever the serializer needs (typically the account); it may be
# nil for models without translations.
#
# ## Output shape
#
# A single record serializes to:
#
#   { <attr> => <value>, ..., "links" => { "<assoc>" => <id|[ids]|{id:,type:}|nil> } }
#
# * Declared `attributes` are emitted as symbol keys, in declaration order
#   (an instance method named after the attribute overrides the column value).
# * `"links"` is a string key whose value is a Hash with string keys, one per
#   declared association, sorted alphabetically.
#   - has_one / belongs_to whose FK lives on the record => the raw id (or nil)
#   - polymorphic has_one / belongs_to => { id: <id>, type: <type> }
#   - has_many => a sorted Array of associated ids ([] when none)
# * created_at / updated_at, when present, are rendered as iso8601(6).
#
# A collection serializes to:
#
#   { <plural_resource_name>: [ <record_hash>, ... ],
#     meta: { total_count:, limit:, offset: } }
class McpToolkit::Serializer::Base
  TIMESTAMP_COLUMNS = %i[created_at updated_at].freeze
  HIGH_PRECISION_FOR_TIMESTAMPS = 6

  # ---- class-level DSL -------------------------------------------------

  Association = Struct.new(:name, :type, :key, :serializer, :polymorphic, :foreign_key, keyword_init: true) do
    # Public-facing key used inside the `links` hash.
    def links_key
      (key || name).to_s
    end
  end

  def self.attributes(*names)
    names.each { |name| declared_attributes << name.to_sym }
  end

  # belongs_to / has_one - single id (or {id:,type:} when polymorphic).
  #
  # `foreign_key:` overrides the FK method read for the id (defaults to
  # `<name>_id`). Use it when the model's FK column doesn't follow the
  # `<name>_id` convention - e.g.
  # `has_one :account, foreign_key: :synced_account_id` so the link reports
  # the central account id straight off the already-loaded column.
  def self.has_one(name, key: nil, root: nil, serializer: nil, polymorphic: false, foreign_key: nil)
    declared_associations << Association.new(
      name: name.to_sym, type: :has_one, key: key || root, serializer:, polymorphic:, foreign_key:
    )
  end

  # has_many / has_and_belongs_to_many - sorted array of ids.
  def self.has_many(name, key: nil, root: nil, serializer: nil)
    declared_associations << Association.new(
      name: name.to_sym, type: :has_many, key: key || root, serializer:, polymorphic: false
    )
  end

  # Declares attributes whose value is a `{ locale => translation }` hash.
  # An instance method is defined for each attribute that delegates to
  # `#translate`. Only meaningful for Globalize models; harmless otherwise
  # (returns {}).
  def self.translates(*names)
    names.each do |name|
      declared_attributes << name.to_sym unless declared_attributes.include?(name.to_sym)
      define_method(name) { translate(name) }
    end
  end

  def self.declared_attributes
    @declared_attributes ||= []
  end

  def self.declared_associations
    @declared_associations ||= []
  end

  # ---- entry points used by the executors (the injection contract) -----

  # Serialize a single record to its attributes+links hash. nil-safe.
  # `fields:` (optional) restricts the output to a sparse fieldset — see the
  # class-level docs.
  def self.serialize_one(record, scope: nil, fields: nil)
    return nil if record.nil?

    new(record, scope:).serializable_hash(fields:)
  end

  # Serialize an array of records to the index wrapper, keyed by the
  # pluralized resource name, with a `meta` pagination block. `fields:` (optional)
  # restricts every row to a sparse fieldset — see the class-level docs.
  def self.serialize_collection(records, scope: nil, total_count: nil, limit: nil, offset: nil, fields: nil)
    rows = Array(records).map { |record| new(record, scope:).serializable_hash(fields:) }
    {
      root_key => rows,
      meta: { total_count: total_count.nil? ? rows.size : total_count, limit:, offset: }
    }
  end

  # Pluralized resource name used as the collection root key, derived from
  # the serialized model (`model.model_name.plural`).
  def self.root_key
    model_class.model_name.plural.to_sym
  end

  # Infer the serialized model from the serializer class name by stripping a
  # trailing "Serializer" and the host namespace, e.g.
  #   Mcp::NotificationSerializer            -> Notification
  #   Mcp::PushNotifications::FilterSerializer -> PushNotifications::Filter
  # Subclasses whose name doesn't follow the convention set `model_class`.
  def self.model_class
    @model_class ||= begin
      without_suffix = name.delete_suffix("Serializer")
      # Drop the leading serializer namespace segment (e.g. "Mcp::") so the
      # remainder names the model. If there is no namespace, use as-is.
      without_namespace = without_suffix.sub(/\A[^:]+::/, "")
      (without_namespace.empty? ? without_suffix : without_namespace).constantize
    end
  end

  # Lets subclasses point at a model whose name doesn't follow the
  # convention (e.g. namespacing differences). Written as an explicit class
  # method (not `attr_writer`, which would define an instance writer) to set the
  # class-level @model_class the convention-inference memoizes.
  def self.model_class=(klass) # rubocop:disable Style/TrivialAccessors
    @model_class = klass
  end

  # ---- instance API ----------------------------------------------------

  attr_reader :object, :scope

  def initialize(object, scope: nil)
    @object = object
    @scope = scope
  end

  # `fields:` (optional) is a sparse fieldset — an array of attribute and/or
  # relationship link-key names to include. nil (default) emits everything.
  def serializable_hash(fields: nil)
    selected = fields&.map(&:to_sym)
    hash = {}
    self.class.declared_attributes.each do |attr|
      next if selected && !selected.include?(attr)

      hash[attr] = read_attribute(attr)
    end
    apply_high_precision_timestamps(hash)
    link_hash = links(selected)
    hash["links"] = link_hash unless link_hash.nil?
    hash
  end
  alias as_json serializable_hash

  private

  def read_attribute(attr)
    # An instance method named after the attribute overrides the column value
    # (AMS convention). Globalize `translates` uses exactly this hook.
    if respond_to?(attr, true) && method(attr).owner != McpToolkit::Serializer::Base
      public_send(attr)
    else
      object.public_send(attr)
    end
  end

  def apply_high_precision_timestamps(hash)
    TIMESTAMP_COLUMNS.each do |column|
      value = hash[column]
      hash[column] = value.iso8601(HIGH_PRECISION_FOR_TIMESTAMPS) if value.present? && value.respond_to?(:iso8601)
    end
  end

  # Builds the `links` hash: association links_key => ids, sorted.
  #
  # `selected` is a sparse fieldset (array of symbols) or nil. With nil the block
  # is always returned (possibly empty `{}`), preserving the default shape. Under
  # a selection only the selected associations are included, AND the whole block
  # is OMITTED (returns nil) when none were selected — so narrowing to a few
  # attributes drops the `links` noise entirely.
  def links(selected = nil)
    associations = self.class.declared_associations
    if selected
      associations = associations.select { |association| selected.include?(association.links_key.to_sym) }
      return nil if associations.empty?
    end
    pairs = associations.map do |association|
      [association.links_key, serialize_ids(association)]
    end
    pairs.sort_by(&:first).to_h
  end

  # Serializes an association to its id(s):
  #   * FK present on the record -> the raw id (polymorphic -> {id:,type:})
  #   * otherwise load the association -> sorted array of ids (has_many)
  #     or single id (has_one).
  def serialize_ids(association)
    fk_method = association.foreign_key || :"#{association.name}_id"

    if object.respond_to?(fk_method)
      if association.polymorphic
        { id: object.public_send(fk_method), type: object.public_send(:"#{association.name}_type") }
      else
        object.public_send(fk_method)
      end
    else
      associated = object.public_send(association.name)
      if associated.respond_to?(:to_ary) || associated.respond_to?(:pluck)
        associated.pluck(:id).sort
      elsif associated
        associated.id
      end
    end
  end

  # Globalize-backed translation: `{ locale => value }`, restricted to the
  # account's selected locales when a scope account is present. Returns {} when
  # the model is not translatable.
  def translate(attribute)
    return {} unless object.respond_to?(:"#{attribute}_translations")

    translations = object.public_send(:"#{attribute}_translations") || {}
    locales = scope_locales
    result = {}
    translations.each do |locale, value|
      locale = locale.to_sym
      next if locales&.exclude?(locale)
      next if value.blank?

      result[locale] = value
    end
    result
  end

  # Locales to restrict translations to. nil means "no restriction" (emit all
  # available translations).
  def scope_locales
    return nil if scope.nil?
    return nil unless scope.respond_to?(:selected_locales)

    selected = scope.selected_locales
    return nil if selected.blank?

    Array(selected).map(&:to_sym)
  end
end
