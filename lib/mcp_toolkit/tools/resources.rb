# frozen_string_literal: true

# Discovery tool: lists every read-only resource exposed by this server.
class McpToolkit::Tools::Resources < McpToolkit::Tools::Base
  tool_name "resources"
  description <<~DESC.strip
    List all read-only resources available via the `list` and `get` tools. Returns each
    resource's name, a short description, whether it accepts filters (`filterable`) and — when
    present — a usage `note` (read it before interpreting the resource's data). Call this once
    at the start of a session to learn what exists, then use `resource_schema` for a specific
    resource's attributes, relationships and filters.
  DESC

  input_schema(properties: {})

  def self.call(server_context:, **_args)
    config = config_from(server_context)
    # Discovery requires the registry-level default scope (the satellite's
    # app-wide scope); per-resource scopes are enforced by `get` / `list`.
    with_authentication(server_context, required_scope: config.registry.default_required_permissions_scope) do
      {
        resources: config.registry.resources.map do |resource|
          {
            name: resource.name,
            description: resource.description,
            filterable: filterable?(resource, config),
            note: resource.note
          }.compact
        end
      }
    end
  end

  # Whether the resource can be filtered at all — via the generic allowlist OR a
  # resource-specific custom filter. Mirrors the authority-path resources tool:
  # resolving a lazily-declared allowlist may run host code, and one resource's
  # failing resolution must not take down the whole discovery index, so a raise
  # degrades to nil (the key is omitted) and the source is retried on the next
  # read (see Resource#filterable).
  def self.filterable?(resource, config)
    resource.filterable_columns.any? || resource.custom_filters.any?
  rescue StandardError => e
    config.logger&.warn("mcp_toolkit: filterable resolution failed for #{resource.name}: #{e.message}")
    nil
  end
  private_class_method :filterable?
end
