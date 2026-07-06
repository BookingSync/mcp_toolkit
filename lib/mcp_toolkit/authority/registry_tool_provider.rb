# frozen_string_literal: true

# A `tool_provider` (the dispatcher's api-agnostic seam) that serves the four
# GENERIC, Registry-backed tools — `resources`, `resource_schema`, `get`, `list` —
# over the resources a host registered in `config.registry`. It is the authority-
# path counterpart to the satellite's SDK tools (McpToolkit::Tools::*): same
# generic contract (discover resources, learn a shape, read one/many rows, all
# account-scoped and read-only), but plugged into the hand-rolled dispatcher.
#
# Satisfies the provider contract the dispatcher calls:
#   tool_definitions(context) -> the four static generic tool definitions
#   find(name)                -> a tool instance bound to this config, or nil
#
# The top-level definitions are context-independent (per-resource visibility and
# scope are enforced inside each tool at call time), so `tool_definitions` ignores
# the context. Compose this with bespoke host tools via CompositeToolProvider.
class McpToolkit::Authority::RegistryToolProvider
  # Tool name (as advertised in `tools/list` and matched in `tools/call`) => the
  # tool class. The four generic read tools; nothing here names an app concept.
  TOOLS = {
    "resources" => McpToolkit::Authority::Tools::Resources,
    "resource_schema" => McpToolkit::Authority::Tools::ResourceSchema,
    "get" => McpToolkit::Authority::Tools::Get,
    "list" => McpToolkit::Authority::Tools::List
  }.freeze

  def initialize(config:)
    @config = config
  end

  # The four static generic tool definitions (context-independent).
  def tool_definitions(_context)
    TOOLS.each_value.map(&:definition)
  end

  # A tool instance bound to this provider's config, or nil for an unknown name.
  def find(name)
    klass = TOOLS[name.to_s]
    klass&.new(config: @config)
  end
end
