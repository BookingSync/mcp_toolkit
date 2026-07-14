# frozen_string_literal: true

# Engine routes, drawn through Rails' routes_reloader so they survive route
# reloads (a class-body `routes.draw` is wiped when the app re-draws the engine's
# route set on boot/reload). Mounted by a satellite or an authority via:
#
#   mount McpToolkit::Engine => "/mcp"
#
#   POST   /mcp                     -> create     (JSON-RPC requests/responses)
#   GET    /mcp                     -> stream     (405; no server-initiated SSE)
#   DELETE /mcp                     -> destroy    (terminate the session)
#   GET    /mcp/health              -> health     (unauthenticated probe)
#   POST   /mcp/tokens/introspect   -> introspect (authority token introspection;
#                                                  drawn ONLY when this app is an
#                                                  authority — see below)
McpToolkit::Engine.routes.draw do
  post "/", to: "server#create"
  get "/", to: "server#stream"
  delete "/", to: "server#destroy"
  get "health", to: "server#health"

  # Introspection is the PROVIDER side of the token protocol. A satellite (the
  # default role) introspects its own tokens AGAINST a central authority and must
  # never itself answer introspection, so the endpoint is drawn only when this app
  # is configured as an authority — a satellite that mounts the full engine gets no
  # such route at all (not merely a failing one). Rails evaluates this file through
  # the routes_reloader, which runs AFTER the host's initializers/to_prepare, so
  # `auth_role` is already set; and the config default is `:satellite`, so an
  # unconfigured host safely omits it. An app that is both keeps it (`authority?`
  # is true whenever `auth_role == :authority`). The controller also fails safe
  # (no `token_authenticator` => `{ valid: false }`), so this is defence in depth.
  post "tokens/introspect", to: "tokens#introspect" if McpToolkit.config.authority?
end
