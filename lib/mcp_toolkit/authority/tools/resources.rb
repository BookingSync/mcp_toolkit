# frozen_string_literal: true

# Authority-path discovery tool: lists every read-only resource registered in the
# config's Registry, HIDING superuser-only resources from a non-superuser caller
# (so they are neither advertised nor discoverable without a superuser token).
#
# The top-level list is context-independent except for that visibility filter, so
# the tool takes no arguments and does no per-resource scope check (per-resource
# scopes are enforced by `get` / `list` / `resource_schema`).
class McpToolkit::Authority::Tools::Resources < McpToolkit::Authority::Tools::Base
  tool_name "resources"
  description <<~DESC.strip
    List all read-only resources available via the `list` and `get` tools. Returns each
    resource's name and a short description. Call this once at the start of a session to learn
    what exists, then use `resource_schema` for a specific resource's attributes and
    relationships.
  DESC

  def call(context:, **_args)
    {
      resources: visible_resources(context).map do |resource|
        { name: resource.name, description: resource.description }
      end
    }
  end

  private

  # Superuser-only resources are hidden from a non-superuser caller.
  def visible_resources(context)
    registry.resources.reject { |resource| resource.superusers_only? && !context.superuser? }
  end
end
