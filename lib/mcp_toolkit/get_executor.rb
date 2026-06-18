# frozen_string_literal: true

module McpToolkit
  # Runs a read-only "show" query for a registered resource by id, rooted on the
  # scoped relation so cross-scope ids are simply not found. Serializes via the
  # resource's serializer. Extracted from bsa-notifications' `McpServer::GetExecutor`.
  class GetExecutor
    def self.call(resource:, scope_root:, id:)
      new(resource:, scope_root:, id:).call
    end

    def initialize(resource:, scope_root:, id:)
      @resource = resource
      @scope_root = scope_root
      @id = id
    end

    def call
      raise McpToolkit::Errors::InvalidParams, "id is required" if @id.blank?

      record = @resource.resolve_relation(@scope_root).find_by(id: @id)
      raise McpToolkit::Errors::InvalidParams, "#{@resource.name} not found for id=#{@id}" unless record

      @resource.serializer.serialize_one(record, scope: @scope_root)
    end
  end
end
