# frozen_string_literal: true

# Mountable Rails engine that draws the MCP transport routes plus the authority
# introspection route (defined in the engine's config/routes.rb so they survive
# Rails' route reloads) against the gem-provided McpToolkit::ServerController /
# McpToolkit::TokensController. A satellite mounts it in one line:
#
#   # config/routes.rb
#   mount McpToolkit::Engine => "/mcp"
#
# yielding exactly the endpoints a hand-rolled satellite declared:
#
#   POST   /mcp                     -> create     (JSON-RPC requests/responses)
#   GET    /mcp                     -> stream     (405; no server-initiated SSE)
#   DELETE /mcp                     -> destroy    (terminate the session)
#   GET    /mcp/health              -> health     (unauthenticated probe)
#   POST   /mcp/tokens/introspect   -> introspect (authority token introspection)
#
# Loaded ONLY when Rails::Engine is available (see lib/mcp_toolkit.rb); the gem's
# non-Rails consumers and its own unit suite never reference it.
class McpToolkit::Engine < Rails::Engine
  isolate_namespace McpToolkit
end
