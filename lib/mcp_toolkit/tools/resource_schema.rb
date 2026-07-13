# frozen_string_literal: true

# Discovery tool: the detailed schema (attributes + relationships) of one
# resource.
class McpToolkit::Tools::ResourceSchema < McpToolkit::Tools::Base
  tool_name "resource_schema"
  description <<~DESC.strip
    Describe a single read-only resource in detail. Pass the resource name as `resource` (use
    the `resources` tool to discover names). Returns:
      - attributes: every field in the response, each with its `type`, a value `format` hint,
        whether it is `filterable`, and the filter `operators` it accepts
      - relationships: associated resources emitted in the record's `links`; each names the
        `target_resource` it resolves to (callable via `list`/`get`)
      - standard_filters: ids, updated_since, limit, offset (accepted by the `list` tool)
      - filters: the per-attribute equality/operator filter keys the `list` tool accepts in
        its `filter` argument
      - resource_filters: resource-specific filters, if any — each is passed as a TOP-LEVEL
        argument of the `list` tool (NOT inside `filter`), e.g. { "resource": "...",
        "<name>": <value> }
    The `attributes` and `relationships` names are also the valid values for the `fields` sparse
    fieldset argument on `get` / `list`. Call this before `list` to learn a resource's shape.
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

  def self.call(server_context:, resource: nil, **_args)
    config = config_from(server_context)
    # Resolve the resource FIRST so its effective required scope gates discovery
    # of THIS resource's shape (and an unknown resource is a clean tool error).
    descriptor = resolve_descriptor(resource, config)
    with_authentication(server_context, required_scope: config.registry.required_scope_for(descriptor)) do
      McpToolkit::ResourceSchema.call(descriptor, registry: config.registry)
    end
  rescue McpToolkit::Errors::InvalidParams => e
    error_response("Invalid request: #{e.message}")
  end
end
