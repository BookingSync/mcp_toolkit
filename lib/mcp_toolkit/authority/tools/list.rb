# frozen_string_literal: true

# Authority-path tool: fetch a paginated list of records from a registered
# resource, scoped to the caller's resolved account. Gates a superuser-only
# resource, the resource's required scope, and requires a selected account before
# reading. Standard filters, per-attribute equality/operator filters, resource
# custom filters, pagination, and sparse fieldsets are all handled by the reused
# McpToolkit::ListExecutor.
class McpToolkit::Authority::Tools::List < McpToolkit::Authority::Tools::Base
  tool_name "list"
  description <<~DESC.strip
    Fetch a paginated list of records from a read-only resource. Pass the resource name as
    `resource`. Use the `resources` tool to discover resources and `resource_schema` to learn a
    resource's shape.

    Standard filters:
      - ids: comma-separated list of IDs to fetch
      - updated_since: ISO 8601 timestamp; only records updated after this time
      - limit: page size (default 25, max 100)
      - offset: pagination offset (default 0)

    Per-attribute filters:
      - filter: an object of { <key>: <value> } filters, applied ON TOP of the account scope
        (they can only narrow, never widen). Each resource advertises its available filter keys
        and operators via `resource_schema`. Unknown keys are rejected.

    Sparse fieldset:
      - fields: names of the attributes and/or relationships to include in each record, as an
        array or a comma-separated string. Omit to return every field. Include "id" if you need
        it. Valid names come from a resource's `resource_schema`; unknown names are rejected.

    For tokens that span multiple accounts (superuser), pass `account_id` to pin the active
    account; account-scoped tokens may omit it. The response shape is
    { "<resource>": [...], "meta": { total_count, limit, offset } }.
  DESC

  input_schema(
    {
      type: "object",
      properties: {
        resource: {
          type: "string",
          description: "Resource name (use the `resources` tool to discover valid values)"
        },
        account_id: {
          type: "integer",
          description: "Account to operate on. Required for superuser tokens; ignored otherwise."
        },
        ids: { type: "string", description: "Comma-separated list of IDs to fetch" },
        updated_since: {
          type: "string",
          description: "ISO 8601 timestamp; only records updated after this time"
        },
        filter: {
          type: "object",
          description: "Per-attribute filters, e.g. { \"booking_id\": 42 }. See a resource's " \
                       "`resource_schema` `filters` for the keys and operators it accepts.",
          additionalProperties: true
        },
        limit: { type: "integer", description: "Page size (default 25, max 100)" },
        offset: { type: "integer", description: "Pagination offset (default 0)" },
        fields: {
          type: %w[array string],
          items: { type: "string" },
          description: "Sparse fieldset — names of attributes and/or relationships to include in " \
                       "each record, as an array or a comma-separated string. Omit to return every " \
                       "field. Include \"id\" if you need it. Unknown names are rejected."
        }
      },
      required: ["resource"]
    }
  )

  def call(context:, resource: nil, **params)
    descriptor = resolve_descriptor(resource)
    ensure_resource_accessible!(descriptor, context)
    ensure_scope!(descriptor, context)
    ensure_account!(context)

    run_executor do
      McpToolkit::ListExecutor.call(resource: descriptor, scope_root: context.account, params:)
    end
  end
end
