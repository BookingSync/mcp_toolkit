# frozen_string_literal: true

# The AUTHORITY-side introspection endpoint, provided BY the gem so a central app
# answers the introspection requests satellites send without writing a controller
# of its own. Mounted by McpToolkit::Engine at `POST /mcp/tokens/introspect`.
#
# Like McpToolkit::ServerController, its parent class is configurable
# (Doorkeeper-style) via `McpToolkit.config.parent_controller`. It authenticates
# the bearer against `config.token_authenticator` (touching last-used) and renders
# the exact payload McpToolkit::Auth::Authority builds — the contract the
# satellite's Auth::Introspection parses.
#
# Drawing the route unconditionally is safe: an app that never configured a
# `token_authenticator` (i.e. is not an authority) answers `{ valid: false }`
# rather than erroring, so mounting the engine on a pure satellite is harmless.
#
# Lives under the gem's app/controllers (an engine path), so it is loaded by
# Rails' autoloader via the engine — never by the gem's own Zeitwerk loader, which
# only manages lib/. Non-Rails consumers never see it.
class McpToolkit::TokensController < McpToolkit.config.parent_controller.constantize
  def introspect
    token = McpToolkit::Auth::Authority.authenticate(mcp_extract_token, config: mcp_config)
    return render(json: McpToolkit::Auth::Authority.invalid_payload, status: :unauthorized) if token.nil?

    render json: McpToolkit::Auth::Authority.introspection_payload(token)
  rescue McpToolkit::Errors::ConfigurationError
    # Not configured as an authority (no token_authenticator): behave as if the
    # token were invalid instead of surfacing a 500.
    render json: McpToolkit::Auth::Authority.invalid_payload, status: :unauthorized
  end

  private

  # Overridable, mirroring the transport concern's `mcp_config` hook.
  def mcp_config
    McpToolkit.config
  end

  # Bearer extraction order: `Authorization: Bearer`, then `X-MCP-Token`, then
  # `?token=`.
  def mcp_extract_token
    auth_header = request.headers["Authorization"]
    return auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")

    request.headers["X-MCP-Token"].presence || params[:token].presence
  end
end
