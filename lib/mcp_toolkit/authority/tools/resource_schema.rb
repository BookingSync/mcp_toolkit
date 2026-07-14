# frozen_string_literal: true

# Authority-path discovery tool: the detailed schema (attributes with types +
# filter operators, relationships, filters, note) of one registered resource.
#
# Reveals shape, not tenant data, so it does NOT require a selected account — but
# it still gates a superuser-only resource (refuse) and the resource's required
# scope, so a caller can't discover the shape of something it can't read.
class McpToolkit::Authority::Tools::ResourceSchema < McpToolkit::Authority::Tools::Base
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
      - filter_examples: ready-to-use `filter` payloads for this resource
    A relationship's `filter` block lists the keys that filter by it; when it names a
    `requires` key (e.g. a polymorphic id needing its type), pass BOTH keys together.
    The `attributes` and `relationships` names are also the valid values for the `fields` sparse
    fieldset argument on `get` / `list`. Call this before `list` to learn a resource's shape.
  DESC

  input_schema(
    {
      type: "object",
      properties: {
        resource: {
          type: "string",
          description: "Resource name (use the `resources` tool to discover valid values)"
        }
      },
      required: ["resource"]
    }
  )

  def call(context:, resource: nil, **extra)
    reject_unknown_arguments!(extra.except(:account_id))
    descriptor = resolve_descriptor(resource)
    ensure_resource_accessible!(descriptor, context)
    ensure_scope!(descriptor, context)

    McpToolkit::ResourceSchema.call(descriptor, registry:)
  end
end
