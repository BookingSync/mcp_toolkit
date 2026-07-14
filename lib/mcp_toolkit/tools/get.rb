# frozen_string_literal: true

# Fetches a single record by id from a registered resource, scoped to the
# resolved scope root.
class McpToolkit::Tools::Get < McpToolkit::Tools::Base
  tool_name "get"
  description <<~DESC.strip
    Fetch a single record by id from a read-only resource. Pass the resource name as `resource`
    and the record id as `id`. Use the `resources` tool to discover available resources.

    For tokens that span multiple accounts (superuser), pass `account_id` to pin the active
    account; account-scoped tokens may omit it. The response mirrors the resource's record
    shape (attributes + a `links` block).

    Pass `fields` to return a sparse fieldset — the attributes and/or relationships you name
    (as an array or comma-separated string), omitting everything else. Include "id" if you need
    it. Valid names come from the resource's `resource_schema`; unknown names are rejected.
  DESC

  input_schema(
    properties: {
      resource: {
        type: "string",
        description: "Resource name (use the `resources` tool to discover valid values)"
      },
      # The id type is left open so a string/UUID primary key works as well as an
      # integer one; the record is looked up by the value as given, uncoerced.
      id: { type: %w[string integer], description: "The record ID (integer or string/UUID)" },
      account_id: {
        type: "integer",
        description: "Account to operate on. Required for superuser tokens; ignored otherwise."
      },
      fields: {
        type: %w[array string],
        items: { type: "string" },
        description: "Sparse fieldset — names of attributes and/or relationships to include, as " \
                     "an array or a comma-separated string. Omit to return every field. Include " \
                     "\"id\" if you need it. Unknown names are rejected; see the resource's " \
                     "`resource_schema` for valid attribute and relationship names."
      }
    },
    required: %w[resource id]
  )

  def self.call(server_context:, resource: nil, id: nil, account_id: nil, fields: nil, **_args)
    config = config_from(server_context)
    # Resolve the resource FIRST so its effective required scope is known before
    # the scope check (and so an unknown resource is a clean tool error).
    descriptor = resolve_descriptor(resource, config)
    required_scope = config.registry.required_scope_for(descriptor)
    with_account(server_context, account_id:, required_scope:, resource: descriptor) do |scope_root|
      McpToolkit::GetExecutor.call(resource: descriptor, scope_root:, id:, fields:)
    end
  rescue McpToolkit::Errors::InvalidParams => e
    error_response("Invalid request: #{e.message}")
  end
end
