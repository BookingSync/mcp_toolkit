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

  # The OAuth authorization bridge (McpToolkit::Oauth::ControllerMethods). Drawn
  # only when the bridge is configured — `oauth_bridge?` is authority-only AND
  # requires a redirect-uri allowlist — so a satellite, or any host that has not
  # opted in, gets no such routes at all. Same reasoning as the introspection
  # route above: the routes file is evaluated through the routes_reloader, after
  # the host's initializers/to_prepare, so the config is already set.
  #
  # `format: false` on each: without it Rails' optional `(.:format)` segment
  # matches, so `/mcp/oauth/authorize.json` reaches the action, finds no JSON
  # template, and 500s — an unauthenticated error on a public endpoint, for a
  # format the bridge never speaks.
  if McpToolkit.config.oauth_bridge?
    get "oauth/authorize", to: "oauth#authorize", format: false
    post "oauth/authorize", to: "oauth#approve", format: false
    post "oauth/token", to: "oauth#token", format: false
    post "oauth/register", to: "oauth#register", format: false

    # The metadata documents, ALSO served path-APPENDED to the mount
    # (`/mcp/.well-known/oauth-authorization-server`), in addition to the RFC 8414
    # §3.1 / RFC 9728 §3.1 path-INSERTED locations the host draws at the origin
    # root via `McpToolkit.draw_oauth_metadata_routes`. A path-ful issuer has two
    # readings of where its metadata lives, and MCP clients disagree: some INSERT
    # the well-known segment before the resource path (the RFC form), others APPEND
    # it after. Observed in the wild — a hosted client requesting
    # `<mcp>/.well-known/oauth-authorization-server` and getting a 404 it could not
    # recover from, so it never reached registration. Serving both meets either
    # convention. Unlike the origin-root bare paths, these stay UNDER the mount, so
    # they claim nothing origin-global and cannot collide with an OAuth provider
    # the host already runs. `openid-configuration` is the OIDC discovery alias a
    # client may probe instead; it answers the same authorization-server document.
    get ".well-known/oauth-authorization-server", to: "oauth#authorization_server", format: false
    get ".well-known/oauth-protected-resource", to: "oauth#protected_resource", format: false
    get ".well-known/openid-configuration", to: "oauth#authorization_server", format: false
  end
end
