# frozen_string_literal: true

# Fetches a paginated list of records from a registered resource, scoped to the
# resolved scope root.
class McpToolkit::Tools::List < McpToolkit::Tools::Base
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

    Per-attribute equality filters:
      - filter: an object of { <key>: <value> } exact-match filters, applied ON TOP of the
        account scope (they can only narrow, never widen). Each resource advertises its
        available filter keys via `resource_schema` (the `filters` array). Unknown keys are
        rejected.

    For tokens that span multiple accounts (superuser), pass `account_id` to pin the active
    account; account-scoped tokens may omit it. The response shape is
    { "<resource>": [...], "meta": { total_count, limit, offset } }.
  DESC

  input_schema(
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
        description: "Per-attribute exact-match equality filters, e.g. { \"booking_id\": 42 }. " \
                     "See a resource's `resource_schema` `filters` for the keys it accepts.",
        additionalProperties: true
      },
      limit: { type: "integer", description: "Page size (default 25, max 100)" },
      offset: { type: "integer", description: "Pagination offset (default 0)" }
    },
    required: ["resource"]
  )

  class << self
    def call(server_context:, resource: nil, account_id: nil, **params)
      config = config_from(server_context)
      with_account(server_context, account_id:) do |scope_root|
        raise McpToolkit::Errors::InvalidParams, "resource is required" if resource.to_s.strip.empty?

        descriptor = lookup_resource(resource, config)
        McpToolkit::ListExecutor.call(resource: descriptor, scope_root:, params:)
      end
    end
  end
end
