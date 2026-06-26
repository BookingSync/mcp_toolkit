# frozen_string_literal: true

# Discovery tool: lists every read-only resource exposed by this server.
class McpToolkit::Tools::Resources < McpToolkit::Tools::Base
  tool_name "resources"
  description <<~DESC.strip
    List all read-only resources available via the `list` and `get` tools. Returns each
    resource's name and a short description. Call this once at the start of a session to learn
    what exists, then use `resource_schema` for a specific resource's attributes and
    relationships.
  DESC

  input_schema(properties: {})

  def self.call(server_context:, **_args)
    config = config_from(server_context)
    # Discovery requires the registry-level default scope (the satellite's
    # app-wide scope); per-resource scopes are enforced by `get` / `list`.
    with_authentication(server_context, required_scope: config.registry.default_required_permissions_scope) do
      {
        resources: config.registry.resources.map do |resource|
          { name: resource.name, description: resource.description }
        end
      }
    end
  end
end
