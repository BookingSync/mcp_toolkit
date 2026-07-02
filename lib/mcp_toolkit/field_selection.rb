# frozen_string_literal: true

# A parsed, validated sparse-fieldset request (JSON:API's `fields[type]`) for a
# single resource. Requested names share ONE flat namespace covering both declared
# ATTRIBUTES and relationship link keys — exactly as JSON:API conflates them.
#
# Built by the List/Get executors from the tool's `fields` argument. A nil
# selection (blank/absent `fields`) means "all fields": the executors skip it
# entirely and serialize as before, so the default path is completely untouched.
#
# A present selection is applied one of two ways, decided by McpToolkit::Serialization:
#   * NATIVELY — `names` is passed to a serializer whose `serialize_one` /
#     `serialize_collection` declares a `fields:` keyword (the gem's Base does),
#     so unselected attributes and relationships are never computed at all.
#   * By PRUNING the fully-serialized hash (`prune_record` / `prune_collection`)
#     for an injected serializer that predates the `fields:` kwarg — a pure
#     shape-level filter, so ANY contract-satisfying serializer stays sparse-able.
class McpToolkit::FieldSelection
  LINKS_KEY = "links"

  # Parse the raw tool argument (a comma-separated string OR an array of names)
  # into a selection, or nil when nothing was requested. Validates the requested
  # names against the resource's known members when the resource can describe them
  # (the Base serializer exposes `declared_attributes`); an unknown name is a
  # clean InvalidParams so a typo is actionable rather than silently dropped.
  def self.build(resource:, raw:)
    names = parse(raw)
    return nil if names.empty?

    new(resource:, names:).tap(&:validate!)
  end

  # Normalizes a CSV string or an array into a de-duplicated list of symbols.
  def self.parse(raw)
    list = raw.is_a?(Array) ? raw : raw.to_s.split(",")
    list.map { |name| name.to_s.strip }.reject(&:empty?).map(&:to_sym).uniq
  end

  # The validated requested field names (symbols), passed to a fields-aware
  # serializer as its `fields:` argument.
  attr_reader :names

  def initialize(resource:, names:)
    @resource = resource
    @names = names
  end

  # Raises InvalidParams if any requested name is neither a declared attribute nor
  # a relationship link key. Skipped for serializers that can't describe their
  # members (resource_schema degrades the same way) — those are pruned leniently.
  def validate!
    return unless @resource.serializer.respond_to?(:declared_attributes)

    unknown = @names - known_members
    return if unknown.empty?

    selectable = known_members.map(&:to_s).sort.join(", ").presence || "(none)"
    raise McpToolkit::Errors::InvalidParams,
          "unknown field(s): #{unknown.join(", ")}. Selectable fields for this resource: #{selectable}"
  end

  # Prune a single serialized record hash down to the requested members.
  # Shape-driven (needs no serializer metadata): every key is an attribute except
  # the string `"links"` block, which is itself narrowed to the requested link
  # keys and dropped entirely when nothing under it was requested.
  def prune_record(hash)
    requested = @names.map(&:to_s)
    hash.each_with_object({}) do |(key, value), pruned|
      if key.to_s == LINKS_KEY
        links = (value || {}).select { |link_key, _| requested.include?(link_key.to_s) }
        pruned[LINKS_KEY] = links unless links.empty?
      elsif requested.include?(key.to_s)
        pruned[key] = value
      end
    end
  end

  # Prune the collection wrapper: each array value holds the rows (prune each);
  # the `meta` hash and any other non-array entry pass through untouched.
  def prune_collection(wrapper)
    wrapper.transform_values do |value|
      value.is_a?(Array) ? value.map { |row| prune_record(row) } : value
    end
  end

  private

  def known_members
    @known_members ||=
      @resource.attribute_names.map(&:to_sym) +
      @resource.association_descriptors.map { |assoc| assoc.links_key.to_sym }
  end
end
