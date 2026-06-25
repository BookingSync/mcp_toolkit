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
      }
    },
    required: %w[resource id]
  )

  def self.call(server_context:, resource: nil, id: nil, account_id: nil, **_args)
    config = config_from(server_context)
    with_account(server_context, account_id:) do |scope_root|
      raise McpToolkit::Errors::InvalidParams, "resource is required" if resource.to_s.strip.empty?

      descriptor = lookup_resource(resource, config)
      McpToolkit::GetExecutor.call(resource: descriptor, scope_root:, id:)
    end
  end
end
