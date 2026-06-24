# frozen_string_literal: true

# Discovery tool: the detailed schema (attributes + relationships) of one
# resource.
class McpToolkit::Tools::ResourceSchema < McpToolkit::Tools::Base
  tool_name "resource_schema"
  description <<~DESC.strip
    Describe a single read-only resource in detail. Pass the resource name as `resource` (use
    the `resources` tool to discover names). Returns:
      - attributes: every field in the response, each with its `type` and a value `format` hint
      - relationships: associated resources emitted in the record's `links`
      - standard_filters: ids, updated_since, limit, offset (accepted by the `list` tool)
      - filters: the per-attribute equality filter keys the `list` tool accepts
    Call this before `list` to learn a resource's shape.
  DESC

  input_schema(
    properties: {
      resource: {
        type: "string",
        description: "Resource name (use the `resources` tool to discover valid values)"
      }
    },
    required: ["resource"]
  )

  class << self
    def call(server_context:, resource: nil, **_args)
      config = config_from(server_context)
      with_authentication(server_context) do
        raise McpToolkit::Errors::InvalidParams, "resource is required" if resource.to_s.strip.empty?

        McpToolkit::ResourceSchema.call(lookup_resource(resource, config))
      end
    end
  end
end
