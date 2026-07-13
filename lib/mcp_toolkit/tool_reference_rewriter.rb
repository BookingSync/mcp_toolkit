# frozen_string_literal: true

# Rewrites backticked generic-tool references ("use the `resources` tool") inside
# tool prose so they always name the tools exactly as they appear in the serving
# server's `tools/list`. Two serving paths need this: the authority's own generic
# tools when the host configures a `generic_tool_name_prefix` (a client would
# otherwise be pointed at an unprefixed tool that does not exist), and the
# gateway's aggregated upstream tools, whose names are re-keyed into the
# `<app>__<tool>` namespace while their prose would otherwise keep naming the
# upstream's bare tools.
#
# Only EXACT backticked base names are rewritten; other backticked terms
# (`resource`, `filter`, `target_resource`, ...) never match.
module McpToolkit::ToolReferenceRewriter
  GENERIC_TOOL_REFERENCES = /`(resource_schema|resources|list|get)`/

  module_function

  # Rewrites `node` (a String, or a Hash/Array structure such as a tool
  # definition or input schema, walked recursively) with `name_prefix` applied to
  # every backticked generic-tool reference. Non-string leaves pass through
  # untouched; an empty prefix returns the node verbatim.
  def rewrite(node, name_prefix)
    return node if name_prefix.to_s.empty?

    case node
    when String then node.gsub(GENERIC_TOOL_REFERENCES) { "`#{name_prefix}#{Regexp.last_match(1)}`" }
    when Hash then node.transform_values { |value| rewrite(value, name_prefix) }
    when Array then node.map { |value| rewrite(value, name_prefix) }
    else node
    end
  end
end
