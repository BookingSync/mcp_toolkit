# frozen_string_literal: true

# Engine routes, drawn through Rails' routes_reloader so they survive route
# reloads (a class-body `routes.draw` is wiped when the app re-draws the engine's
# route set on boot/reload). Mounted by a satellite via:
#
#   mount McpToolkit::Engine => "/mcp"
#
#   POST   /mcp                     -> create     (JSON-RPC requests/responses)
#   GET    /mcp                     -> stream     (405; no server-initiated SSE)
#   DELETE /mcp                     -> destroy    (terminate the session)
#   GET    /mcp/health              -> health     (unauthenticated probe)
#   POST   /mcp/tokens/introspect   -> introspect (authority token introspection)
McpToolkit::Engine.routes.draw do
  post "/", to: "server#create"
  get "/", to: "server#stream"
  delete "/", to: "server#destroy"
  get "health", to: "server#health"
  post "tokens/introspect", to: "tokens#introspect"
end
