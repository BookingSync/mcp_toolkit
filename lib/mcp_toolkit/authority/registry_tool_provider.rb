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
  # BASE tool name (the api-agnostic identity of each generic tool) => the tool
  # class. The four generic read tools; nothing here names an app concept. The name
  # actually advertised in `tools/list` and matched in `tools/call` is this base
  # name PREFIXED with `config.generic_tool_name_prefix` (empty by default, so the
  # bare base name), letting a host namespace its generic tools.
  TOOLS = {
    "resources" => McpToolkit::Authority::Tools::Resources,
    "resource_schema" => McpToolkit::Authority::Tools::ResourceSchema,
    "get" => McpToolkit::Authority::Tools::Get,
    "list" => McpToolkit::Authority::Tools::List
  }.freeze

  def initialize(config:)
    @config = config
  end

  # The four static generic tool definitions (context-independent), each advertised
  # under its PREFIXED name so `tools/list` shows the host's namespaced names. The
  # prefix is threaded into each definition so sibling-tool references in the
  # description / input schema name the prefixed tools too (see Tools::Base.definition).
  def tool_definitions(_context)
    TOOLS.map { |_base_name, klass| klass.definition(name_prefix: prefix) }
  end

  # A tool instance bound to this provider's config, or nil for an unknown name.
  # The incoming name is matched against the PREFIXED names: the prefix is stripped
  # to recover the base tool, so a name that does not carry the configured prefix
  # (e.g. a sibling provider's unprefixed tool) is left for another provider.
  def find(name)
    base_name = base_name_for(name.to_s)
    klass = base_name && TOOLS[base_name]
    klass&.new(config: @config)
  end

  private

  # The host's generic tool-name prefix (empty by default).
  def prefix
    @config.generic_tool_name_prefix.to_s
  end

  # Recovers the base tool name from an advertised name by stripping the configured
  # prefix, or nil when the name does not carry the (non-empty) prefix.
  def base_name_for(name)
    return name if prefix.empty?
    return nil unless name.start_with?(prefix)

    name.delete_prefix(prefix)
  end
end
