# frozen_string_literal: true

# Bridges the executors to a resource's serializer while honoring a sparse
# McpToolkit::FieldSelection. Built per call with the serializer and the (possibly
# nil) selection; `#one` / `#collection` then mirror the serializer contract. This
# is the single place that keeps the injectable serializer contract intact as
# sparse fieldsets are added:
#
#   * selection nil (the default) -> the serializer is called EXACTLY as before
#     (no `fields:` kwarg), so existing behavior and injected serializers are
#     untouched.
#   * selection present, serializer declares a `fields:` keyword (the gem's Base)
#     -> applied NATIVELY, skipping the compute for unselected members.
#   * selection present, serializer predates the kwarg -> the full output is
#     PRUNED to the selection, so any contract-satisfying serializer stays
#     sparse-able without change.
class McpToolkit::Serialization
  # `Method#parameters` types that mean a keyword the caller may pass by name.
  FIELDS_KEYWORD_TYPES = %i[key keyreq].freeze

  def initialize(serializer, selection)
    @serializer = serializer
    @selection = selection
  end

  def one(record, scope:)
    return @serializer.serialize_one(record, scope:) if @selection.nil?

    if accepts_fields?(:serialize_one)
      @serializer.serialize_one(record, scope:, fields: @selection.names)
    else
      result = @serializer.serialize_one(record, scope:)
      result && @selection.prune_record(result)
    end
  end

  def collection(records, scope:, total_count:, limit:, offset:)
    return full_collection(records, scope:, total_count:, limit:, offset:) if @selection.nil?

    if accepts_fields?(:serialize_collection)
      @serializer.serialize_collection(records, scope:, total_count:, limit:, offset:, fields: @selection.names)
    else
      @selection.prune_collection(full_collection(records, scope:, total_count:, limit:, offset:))
    end
  end

  private

  def full_collection(records, scope:, total_count:, limit:, offset:)
    @serializer.serialize_collection(records, scope:, total_count:, limit:, offset:)
  end

  # True only when the method declares an EXPLICIT `fields:` keyword. A serializer
  # that merely absorbs `**kwargs` is deliberately NOT treated as fields-aware — it
  # would ignore the selection and silently return the full shape — so it falls
  # through to output pruning, which guarantees the response is actually narrowed.
  def accepts_fields?(method_name)
    @serializer.method(method_name).parameters.any? do |type, name|
      name == :fields && FIELDS_KEYWORD_TYPES.include?(type)
    end
  end
end
