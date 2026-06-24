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
  end

  def register(name, &)
    resource = McpToolkit::Resource.new(name)
    resource.instance_eval(&)
    @resources[name.to_s] = resource
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

  def reset!
    @resources = {}
  end
end
