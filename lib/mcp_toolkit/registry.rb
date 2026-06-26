# frozen_string_literal: true

# Central registry of read-only resources exposed via the MCP server. Resources
# are registered at boot (in a `to_prepare` initializer) and consumed by the
# generic `resources` / `resource_schema` / `get` / `list` tools.
#
# Instances are addressable so tests (and, in principle, multiple mounted
# servers) don't collide; the app-facing convenience is `McpToolkit.registry`,
# which returns the process-wide instance.
class McpToolkit::Registry
  class UnknownResource < StandardError; end

  def initialize
    @resources = {}
    @default_required_permissions_scope = nil
  end

  # Registry-wide DEFAULT required scope, so a satellite declares its scope ONCE
  # for every resource instead of repeating it per resource:
  #
  #   McpToolkit.registry.default_required_permissions_scope "notifications__read"
  #
  # A resource's own `required_permissions_scope` overrides this. Default nil = no
  # scope required unless a resource declares its own. Read with no arg.
  #
  # Declared in the satellite's `configure` block (NOT inside `to_prepare`), so it
  # survives `reset!` and stays set across dev reloads.
  def default_required_permissions_scope(scope = nil)
    @default_required_permissions_scope = scope if scope
    @default_required_permissions_scope
  end

  def register(name, &)
    resource = McpToolkit::Resource.new(name)
    resource.instance_eval(&)
    @resources[name.to_s] = resource
  end

  # The scope a token must carry to reach `resource` via the generic tools: the
  # resource's own declared scope, else the registry default, else nil (no check).
  def required_scope_for(resource)
    resource.effective_required_permissions_scope(@default_required_permissions_scope)
  end

  def fetch(name)
    find(name) or raise(UnknownResource, "unknown resource: #{name.inspect}")
  end

  def find(name)
    @resources[name.to_s]
  end

  def resources
    @resources.values
  end

  def resource_names
    @resources.keys
  end

  # Clears registered resources for a dev reload (the satellite re-declares them
  # in `to_prepare`). The `default_required_permissions_scope` is PRESERVED, since
  # it's declared once in `configure` rather than per-reload.
  def reset!
    @resources = {}
  end
end
