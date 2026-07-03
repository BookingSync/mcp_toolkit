# frozen_string_literal: true

# The MCP Streamable-HTTP transport, provided as an includable concern. An
# app's controller includes this to get the full transport with no per-app code:
#
#   class Mcp::ServerController < ApplicationController
#     include McpToolkit::Transport::ControllerMethods
#   end
#
# and routes the four endpoints at its actions:
#
#   post   "mcp",        to: "mcp/server#create"
#   get    "mcp",        to: "mcp/server#stream"
#   delete "mcp",        to: "mcp/server#destroy"
#   get    "mcp/health", to: "mcp/server#health"
#
# Endpoints
#   POST   /mcp          - JSON-RPC requests/responses
#   GET    /mcp          - server-initiated SSE stream (none emitted; 405)
#   DELETE /mcp          - terminate the current session
#   GET    /mcp/health   - unauthenticated health probe
#
# Authentication
#   The bearer token is NOT verified at the transport boundary; it is forwarded
#   into each tool, which authenticates it against the central app's
#   introspection endpoint (McpToolkit::Auth::Authenticator). The transport only
#   requires that *a* token be present (so unauthenticated calls are refused
#   before any work). Tools resolve the active account from `_meta` /
#   `account_id` argument / the account-id header.
#
# Session lifecycle
#   - First `initialize` POST: create a session, return its id in the
#     `Mcp-Session-Id` response header. The client echoes it on later requests.
#   - Subsequent POSTs: validate the session id; missing/expired => 404.
#   - DELETE /mcp ends the session.
#
# Notifications (requests without an `id`) get a 202 with no body.
#
# Overridable hooks
#   - `mcp_config`      -> the McpToolkit::Configuration to use (default: McpToolkit.config)
#   - `mcp_extra_tools` -> Array of additional MCP::Tool subclasses (default: [])
#
# CSRF: the concern disables forgery protection (this is a token-authenticated
# JSON API). Inherit from ActionController::Base (not ::API) if your app's
# controller stack needs helper_method, as bsa-notifications does.
module McpToolkit::Transport::ControllerMethods
  extend ActiveSupport::Concern

  SESSION_HEADER = "Mcp-Session-Id"

  included do
    protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)

    before_action :mcp_require_token!, except: [:health]
    before_action :mcp_resolve_session!, only: [:create]
  end

  def create
    request_body = mcp_parsed_body
    server = McpToolkit::Server.build(
      server_context: mcp_server_context,
      config: mcp_config,
      extra_tools: mcp_extra_tools
    )
    response_json = server.handle_json(JSON.generate(request_body))

    # handle_json returns nil for notifications (no id) -> 202 Accepted, no body.
    return head :accepted if response_json.nil?

    mcp_render_response(response_json)
  end

  # GET /mcp - no server-initiated SSE stream is emitted; 405 per MCP spec.
  def stream
    head :method_not_allowed
  end

  # DELETE /mcp - terminate the current session.
  def destroy
    McpToolkit::Session.delete(request.headers[SESSION_HEADER], config: mcp_config)
    head :no_content
  end

  # GET /mcp/health - unauthenticated probe.
  def health
    render json: {
      status: "ok",
      server: mcp_config.server_name,
      version: mcp_config.server_version
    }
  end

  private

  # ---- overridable hooks ----------------------------------------------

  def mcp_config
    McpToolkit.config
  end

  def mcp_extra_tools
    []
  end

  # Logger for transport-level diagnostics. Defaults to Rails.logger when running
  # inside Rails (nil outside it); overridable so a host can inject its own.
  def mcp_logger
    return Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)

    nil
  end

  # ---- per-request context --------------------------------------------

  # Per-request context threaded to the tools. The gem merges the request's
  # `_meta` into this hash (as `:_meta`) at tool-call time.
  def mcp_server_context
    {
      bearer_token: mcp_extract_token,
      header_account_id: request.headers[mcp_config.account_id_header].presence,
      mcp_config: mcp_config
    }
  end

  # Renders the JSON-RPC payload as application/json by default, or as a single
  # SSE `message` frame when the client's Accept header asks for it. We never
  # actually stream (one message + EOF) so a strict client interoperates either
  # way.
  def mcp_render_response(response_json)
    if mcp_event_stream_requested?
      response.headers["Cache-Control"] = "no-cache"
      body = "event: message\ndata: #{response_json}\n\n"
      render body:, content_type: Mime::Type.lookup("text/event-stream").to_s
    else
      render json: response_json
    end
  end

  def mcp_event_stream_requested?
    request.headers["Accept"].to_s.include?("text/event-stream")
  end

  # ---- auth (presence only; real auth is per-tool) --------------------

  # A token must be present; its validity is enforced per-tool. Extraction
  # order: Bearer header, then X-MCP-Token, then ?token=.
  def mcp_require_token!
    return if mcp_extract_token.present?

    mcp_render_unauthorized("Missing authorization token")
  end

  def mcp_extract_token
    auth_header = request.headers["Authorization"]
    return auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")

    request.headers["X-MCP-Token"].presence || params[:token].presence
  end

  # ---- session lifecycle ----------------------------------------------

  # POST: create a session on `initialize`, otherwise require an existing one.
  def mcp_resolve_session!
    methods = mcp_methods_from(mcp_parsed_body)

    if methods.include?("initialize")
      @mcp_session = McpToolkit::Session.create!(config: mcp_config)
    else
      @mcp_session = McpToolkit::Session.find(request.headers[SESSION_HEADER], config: mcp_config)
      return mcp_render_session_not_found if @mcp_session.nil?
    end

    response.headers[SESSION_HEADER] = @mcp_session.id
  end

  def mcp_methods_from(request_body)
    # Array.wrap (not Kernel#Array): a single JSON-RPC Hash must wrap to
    # [hash], whereas Kernel#Array(hash) would explode it into [[k, v], ...].
    Array.wrap(request_body).filter_map { |req| req.is_a?(Hash) ? req["method"] : nil }
  end

  def mcp_parsed_body
    return @mcp_parsed_body if defined?(@mcp_parsed_body)

    @mcp_parsed_body = JSON.parse(request.body.read)
  rescue JSON::ParserError
    @mcp_parsed_body = {}
  end

  # ---- error renders ---------------------------------------------------

  def mcp_render_unauthorized(message)
    render json: {
      jsonrpc: "2.0",
      id: nil,
      error: { code: -32_000, message: "Unauthorized: #{message}" }
    }, status: :unauthorized
  end

  def mcp_render_session_not_found
    mcp_log_session_not_found
    render json: {
      jsonrpc: "2.0",
      id: nil,
      error: { code: -32_001, message: "Session not found or expired" }
    }, status: :not_found
  end

  # Warns (greppable, no id/token) when a POST arrives with no matching session.
  # The common cause is a session created on one process but looked up on another
  # because `cache_store` isn't a shared store — invisible otherwise, since the
  # caller just sees a 404. Records only whether a session-id header was PRESENT so
  # a header-missing client bug is distinguishable from a cache misconfiguration.
  def mcp_log_session_not_found
    logger = mcp_logger
    return unless logger

    header_present = request.headers[SESSION_HEADER].present?
    logger.warn(
      "[McpToolkit] MCP session not found or expired " \
      "(#{SESSION_HEADER} header present: #{header_present}). If sessions are created but not " \
      "found, cache_store is likely not shared across processes (set it to a shared store, e.g. Rails.cache)."
    )
  end
end
