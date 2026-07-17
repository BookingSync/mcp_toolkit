# frozen_string_literal: true

# Mountable Rails engine that draws the MCP transport routes plus the authority
# introspection route (defined in the engine's config/routes.rb so they survive
# Rails' route reloads) against the gem-provided McpToolkit::ServerController /
# McpToolkit::TokensController. A satellite OR an authority mounts it in one line:
#
#   # config/routes.rb
#   mount McpToolkit::Engine => "/mcp"
#
# The mounted McpToolkit::ServerController is role-aware (built lazily from
# config.auth_role): an authority host gets the hand-rolled dispatcher path, a
# satellite gets the SDK-backed one — see engine_controllers.rb. This yields
# exactly the endpoints a hand-rolled host declared:
#
#   POST   /mcp                     -> create     (JSON-RPC requests/responses)
#   GET    /mcp                     -> stream     (405; no server-initiated SSE)
#   DELETE /mcp                     -> destroy    (terminate the session)
#   GET    /mcp/health              -> health     (unauthenticated probe)
#   POST   /mcp/tokens/introspect   -> introspect (authority token introspection;
#                                                  drawn ONLY when auth_role is
#                                                  :authority — a satellite that
#                                                  mounts the engine gets no such
#                                                  route)
#
# Loaded ONLY when Rails::Engine is available (see lib/mcp_toolkit.rb); the gem's
# non-Rails consumers and its own unit suite never reference it.
class McpToolkit::Engine < Rails::Engine
  isolate_namespace McpToolkit

  # The gem-provided controllers subclass `config.parent_controller`, which the
  # host sets in an initializer/to_prepare that must be READ AFTER it runs
  # (Constraint B). They are therefore built lazily by
  # `McpToolkit.build_engine_controllers!` (triggered via const_missing on first
  # reference — at eager-load or first request). This resets them on every code
  # reload so a changed parent (or a reloaded app parent class) takes effect on the
  # next reference. Runs before `:eager_load!`, so the fresh classes exist for it.
  config.to_prepare { McpToolkit.reset_engine_controllers! }

  # The OAuth bridge takes the operator's live access token in a POST body, and
  # Rails logs request parameters at INFO. Filtering it is therefore the gem's
  # business, not a deployment note: a `rails new` app happens to ship a `:token`
  # entry that covers `access_token` by substring, but that is a host default this
  # gem does not own and an `--api` or hand-rolled host may not have. Additive, so
  # a host's own list is untouched, and harmless when the bridge is off.
  #
  # `code_verifier` is belt-and-braces (a logged verifier is worthless once the
  # code is spent, and the code is burnt on read). `code` is deliberately NOT
  # filtered: it is single-use, useless without the verifier, and matching it
  # would filter every `country_code`/`state_code` a host logs.
  initializer "mcp_toolkit.filter_oauth_parameters" do |app|
    app.config.filter_parameters += %i[access_token code_verifier]
  end
end
