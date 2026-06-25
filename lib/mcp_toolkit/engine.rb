# frozen_string_literal: true

# Mountable Rails engine that draws the four MCP transport routes (defined in the
# engine's config/routes.rb so they survive Rails' route reloads) against the
# gem-provided McpToolkit::ServerController. A satellite mounts it in one line:
#
#   # config/routes.rb
#   mount McpToolkit::Engine => "/mcp"
#
# yielding exactly the endpoints a hand-rolled satellite declared:
#
#   POST   /mcp          -> create   (JSON-RPC requests/responses)
#   GET    /mcp          -> stream   (405; no server-initiated SSE)
#   DELETE /mcp          -> destroy  (terminate the session)
#   GET    /mcp/health   -> health   (unauthenticated probe)
#
# Loaded ONLY when Rails::Engine is available (see lib/mcp_toolkit.rb); the gem's
# non-Rails consumers and its own unit suite never reference it.
class McpToolkit::Engine < Rails::Engine
  isolate_namespace McpToolkit
end
