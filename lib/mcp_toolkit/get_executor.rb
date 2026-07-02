# frozen_string_literal: true

# Runs a read-only "show" query for a registered resource by id, rooted on the
# scoped relation so cross-scope ids are simply not found. Serializes via the
# resource's serializer.
class McpToolkit::GetExecutor
  def self.call(resource:, scope_root:, id:, fields: nil)
    new(resource:, scope_root:, id:, fields:).call
  end

  def initialize(resource:, scope_root:, id:, fields: nil)
    @resource = resource
    @scope_root = scope_root
    @id = id
    @fields = fields
  end

  def call
    raise McpToolkit::Errors::InvalidParams, "id is required" if id.blank?

    # Validate the sparse fieldset BEFORE the lookup so a bad `fields` fails fast.
    selection = McpToolkit::FieldSelection.build(resource:, raw: fields)
    record = resource.resolve_relation(scope_root).find_by(id:)
    raise McpToolkit::Errors::InvalidParams, "#{resource.name} not found for id=#{id}" unless record

    McpToolkit::Serialization.new(resource.serializer, selection).one(record, scope: scope_root)
  end

  private

  attr_reader :resource, :scope_root, :id, :fields
end
