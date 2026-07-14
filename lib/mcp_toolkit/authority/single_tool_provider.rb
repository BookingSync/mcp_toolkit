# frozen_string_literal: true

# A `tool_provider` serving exactly one bespoke authority tool alongside the
# generic Registry-backed ones — the shape every host with a single custom tool
# would otherwise hand-roll. Used automatically by the composed default
# provider for bare tool classes in `config.extra_tool_providers`.
#
# The tool must expose `.definition` (the tools/list entry) and `.tool_name`,
# and itself satisfy the dispatcher's tool contract (`required_permissions_scope`
# + `call`) — e.g. a class built on McpToolkit::Tools::AuthorityBase. It is
# advertised unconditionally; its scope/authorization gates are enforced at
# call time (by the dispatcher and the tool itself).
class McpToolkit::Authority::SingleToolProvider
  def initialize(tool)
    @tool = tool
  end

  def tool_definitions(_context)
    [@tool.definition]
  end

  def find(name)
    name.to_s == @tool.tool_name ? @tool : nil
  end
end
