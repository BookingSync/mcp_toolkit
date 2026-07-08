# frozen_string_literal: true

# Authority-path tool: fetch a single record by id from a registered resource,
# scoped to the caller's resolved account. Gates a superuser-only resource, the
# resource's required scope, and requires a selected account before reading.
class McpToolkit::Authority::Tools::Get < McpToolkit::Authority::Tools::Base
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
    {
      type: "object",
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
                       "\"id\" if you need it. Unknown names are rejected."
        }
      },
      required: %w[resource id]
    }
  )

  def call(context:, resource: nil, id: nil, fields: nil, **_args)
    descriptor = resolve_descriptor(resource)
    ensure_resource_accessible!(descriptor, context)
    ensure_scope!(descriptor, context)
    ensure_account!(context)

    run_executor do
      McpToolkit::GetExecutor.call(resource: descriptor, scope_root: context.account, id:, fields:)
    end
  end
end
