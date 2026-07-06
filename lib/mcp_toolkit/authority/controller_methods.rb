# frozen_string_literal: true

# The AUTHORITY-side MCP Streamable-HTTP transport, provided as an includable
# concern. Unlike the satellite transport (McpToolkit::Transport::ControllerMethods,
# which forwards a token to a central app for per-tool introspection), the
# authority AUTHENTICATES the token locally and dispatches through the hand-rolled
# McpToolkit::Dispatcher, serving its own tools and (as a gateway) proxying
# upstreams.
#
# Because the POST endpoint is the billing/tenancy boundary of a first-party
# server, EVERY billing/tenancy step is an overridable hook. A pure host can drive
# the whole thing from config callables (`rate_limiter`, `usage_recorder`,
# `usage_flusher`, `tool_provider`, `token_authenticator`); a host whose metering
# touches its own models subclasses McpToolkit::Authority::ServerController and
# overrides the hook methods directly (the recommended path).
#
# Endpoints
#   POST   /mcp          - JSON-RPC requests/responses (single or batch)
#   GET    /mcp          - server-initiated SSE stream (none emitted; 405)
#   DELETE /mcp          - terminate the current session
#   GET    /mcp/health   - unauthenticated health probe
#
# Per-request loop (the metering-critical invariant)
#   Each JSON-RPC call — including every element of a batch — RE-RESOLVES its
#   account from its own `_meta` / `account_id` argument, then tracks usage, then
#   dispatches with a fresh Authority::Context. The batch is deliberately NOT
#   delegated to a bulk handler that can't re-resolve per element, so a mixed-
#   account batch still meters one usage event per call against the right account.
#
# Overridable hooks (defaults in parentheses)
#   mcp_config          -> the McpToolkit::Configuration (McpToolkit.config)
#   mcp_authenticate!   -> set @mcp_principal or render 401 (local token auth via
#                          config.token_authenticator, through Auth::Authority)
#   mcp_rate_limit!     -> throttle (built-in McpToolkit::RateLimiter when
#                          config.rate_limit_max_requests is set; config.rate_limiter
#                          escape hatch takes precedence; no-op when neither)
#   mcp_track_usage     -> record one usage event (config.usage_recorder&.call)
#   mcp_flush_usage     -> persist accumulated usage (config.usage_flusher&.call)
#   mcp_resolve_account -> the account for one call (principal#default_account /
#                          principal#authorize_account(id))
#   mcp_session_data    -> opaque payload bound to the session ({}; a host binds
#                          e.g. { token_id: principal.id } so a revoked token kills
#                          the session)
#   mcp_dispatch        -> run one JSON-RPC call (Dispatcher + Authority::Context)
#   mcp_health_payload  -> the GET /mcp/health body
#
# CSRF: the concern disables forgery protection (this is a token-authenticated
# JSON API). Its host controller should inherit from ActionController::API (or
# ::Base with null_session) via `config.parent_controller`.
module McpToolkit::Authority::ControllerMethods
  extend ActiveSupport::Concern

  SESSION_HEADER = "Mcp-Session-Id"

  included do
    protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)

    before_action :mcp_authenticate!, except: [:health]
    before_action :mcp_rate_limit!, except: [:health]
    before_action :mcp_resolve_session!, only: [:create]
    before_action :mcp_require_session!, only: [:destroy]
    after_action :mcp_flush_usage
  end

  def create
    request_body = mcp_parse_body

    if request_body.is_a?(Array)
      mcp_handle_batch(request_body)
    else
      mcp_handle_single(request_body)
    end
  end

  # GET /mcp — opens an SSE stream for server-initiated messages. None are emitted
  # (no sampling, progress, or notifications today), so we reply 405 as the MCP
  # spec explicitly allows.
  def stream
    head :method_not_allowed
  end

  # DELETE /mcp — terminate the current session.
  def destroy
    McpToolkit::Session.delete(request.headers[SESSION_HEADER], config: mcp_config)
    head :no_content
  end

  # GET /mcp/health — unauthenticated health probe.
  def health
    render json: mcp_health_payload
  end

  private

  # ---- overridable hooks ----------------------------------------------

  def mcp_config
    McpToolkit.config
  end

  # The authenticated principal for this request (the token object), set by
  # mcp_authenticate!. Read by the other hooks.
  def mcp_principal
    @mcp_principal
  end

  # Authenticate the bearer LOCALLY (the authority's job). The default resolves it
  # through Auth::Authority (config.token_authenticator), which also touches
  # last-used. Renders a JSON-RPC 401 and halts on a missing/invalid token.
  def mcp_authenticate!
    token = mcp_extract_token
    return mcp_render_unauthorized("Missing authorization token") if token.blank?

    @mcp_principal = McpToolkit::Auth::Authority.authenticate(token, config: mcp_config)
    mcp_render_unauthorized("Invalid or expired token") unless @mcp_principal
  end

  # Throttle the request. Precedence:
  #   1. `config.rate_limiter` escape hatch, if set (host-owned counting);
  #   2. otherwise the built-in McpToolkit::RateLimiter when a cap is configured
  #      (via the `mcp_rate_limit_max_requests` hook, default
  #      `config.rate_limit_max_requests`);
  #   3. otherwise a no-op (no cap => pure host unaffected).
  # On every capped request it sets the X-RateLimit-* headers; over the limit it
  # additionally sets Retry-After and renders the JSON-RPC error + 429 (halting
  # the filter chain).
  def mcp_rate_limit!
    return mcp_config.rate_limiter.call(controller: self, principal: mcp_principal) if mcp_config.rate_limiter

    max = mcp_rate_limit_max_requests
    return if max.nil?

    result = McpToolkit::RateLimiter.new(
      key: mcp_rate_limit_key,
      max_requests: max,
      window: mcp_config.rate_limit_window,
      cache_store: mcp_config.cache_store
    ).call

    mcp_set_rate_limit_headers(result)
    mcp_render_rate_limited(result) unless result.allowed?
  end

  # The per-window request cap the built-in limiter enforces, or nil to disable
  # it. Default: `config.rate_limit_max_requests`. A host that keeps its cap in a
  # constant/model overrides this (e.g. `= MyController::RATE_LIMIT`).
  def mcp_rate_limit_max_requests
    mcp_config.rate_limit_max_requests
  end

  # The identity the built-in limiter counts against. Default: the principal id.
  # Override to bucket differently (e.g. per account, or a composite key).
  def mcp_rate_limit_key
    mcp_principal.id
  end

  # Sets the X-RateLimit-* headers from a RateLimiter result (on every capped
  # response, allowed or not).
  def mcp_set_rate_limit_headers(result)
    response.headers["X-RateLimit-Limit"] = result.limit.to_s
    response.headers["X-RateLimit-Reset"] = result.reset_at.to_s
    response.headers["X-RateLimit-Remaining"] = result.remaining.to_s
  end

  # Renders the over-limit response: the Retry-After header plus a JSON-RPC error
  # envelope (code -32029) at HTTP 429. Called as a before_action, so the render
  # halts the request.
  def mcp_render_rate_limited(result)
    response.headers["Retry-After"] = result.retry_after.to_s
    render json: {
      jsonrpc: McpToolkit::Protocol::JSONRPC_VERSION,
      id: nil,
      error: {
        code: -32_029,
        message: "Rate limit exceeded. Retry after #{result.retry_after}s."
      }
    }, status: :too_many_requests
  end

  # Record one usage event for a single JSON-RPC call. The default delegates to
  # `config.usage_recorder`; a host that accumulates into its own ledger overrides
  # this. MUST never affect the MCP response.
  def mcp_track_usage(request_data, account)
    mcp_config.usage_recorder&.call(
      request_data:, account:, principal: mcp_principal, controller: self
    )
  end

  # Persist accumulated usage (after_action). The default delegates to
  # `config.usage_flusher`. MUST never affect the MCP response.
  def mcp_flush_usage
    mcp_config.usage_flusher&.call(controller: self)
  end

  # Pick the active account for a SINGLE JSON-RPC call. Duck-typed on the
  # principal: no candidate -> its default account (nil for a multi-account
  # token); a candidate -> the authorized account or a JSON-RPC InvalidParams.
  def mcp_resolve_account(request_data)
    candidate = mcp_candidate_account_id(request_data)
    return mcp_principal.default_account if candidate.blank?

    account = mcp_principal.authorize_account(candidate)
    return account if account

    raise McpToolkit::Protocol::InvalidParams, "account_id #{candidate.inspect} is not authorized for this token"
  end

  # Opaque payload bound to the session on `initialize`. Default: none. A host
  # binds e.g. `{ token_id: mcp_principal.id }` so a revoked token can kill an
  # in-flight session.
  def mcp_session_data
    {}
  end

  # Run one JSON-RPC call through the hand-rolled dispatcher with a fresh
  # per-request context.
  def mcp_dispatch(request_data, account)
    context = McpToolkit::Authority::Context.new(
      account:, principal: mcp_principal, bearer_token: mcp_extract_token
    )
    McpToolkit::Dispatcher.new(context:, config: mcp_config).handle_request(request_data)
  end

  def mcp_health_payload
    {
      status: "ok",
      server: mcp_config.server_name,
      version: mcp_config.server_version,
      protocol_version: McpToolkit::Protocol::LATEST_VERSION
    }
  end

  # ---- request handling -----------------------------------------------

  def mcp_handle_batch(requests)
    responses = requests.filter_map { |req| mcp_process_single_request(req) }
    return head :accepted if responses.empty?

    mcp_render_response(responses)
  end

  def mcp_handle_single(request_data)
    response_data = mcp_process_single_request(request_data)
    return head :accepted if response_data.nil?

    mcp_render_response(response_data)
  end

  # The per-request loop body: resolve THIS call's account, meter it, dispatch.
  # A protocol error raised while resolving the account (e.g. an unauthorized
  # account id) becomes this call's JSON-RPC error, leaving sibling batch elements
  # untouched.
  def mcp_process_single_request(request_data)
    account = mcp_resolve_account(request_data)
    mcp_track_usage(request_data, account)
    mcp_dispatch(request_data, account)
  rescue McpToolkit::Protocol::Error => e
    return nil unless request_data.is_a?(Hash) && request_data.key?("id")

    McpToolkit::Protocol.error_response(id: request_data["id"], error: e)
  end

  # Renders the JSON-RPC payload as application/json (default) or text/event-stream
  # when the client's Accept header includes "text/event-stream". We never actually
  # stream — one message then EOF — but emitting SSE on demand keeps strict MCP
  # clients happy.
  def mcp_render_response(payload)
    if mcp_event_stream_requested?
      mcp_render_sse_stream(payload)
    else
      render json: payload
    end
  end

  def mcp_render_sse_stream(payload)
    response.headers["Cache-Control"] = "no-cache"
    messages = payload.is_a?(Array) ? payload : [payload]
    body = messages.map { |message| mcp_format_sse_event(message) }.join

    render body:, content_type: Mime::Type.lookup("text/event-stream").to_s
  end

  def mcp_format_sse_event(message)
    "event: message\ndata: #{message.to_json}\n\n"
  end

  def mcp_event_stream_requested?
    request.headers["Accept"].to_s.include?("text/event-stream")
  end

  # ---- session lifecycle ----------------------------------------------

  # POST: create a session on `initialize` (binding mcp_session_data), otherwise
  # require an existing one.
  def mcp_resolve_session!
    methods = mcp_methods_from(mcp_parse_body)

    if methods.include?("initialize")
      @mcp_session = McpToolkit::Session.create!(data: mcp_session_data, config: mcp_config)
    else
      @mcp_session = McpToolkit::Session.find(request.headers[SESSION_HEADER], config: mcp_config)
      return mcp_render_session_not_found if @mcp_session.nil?
    end

    response.headers[SESSION_HEADER] = @mcp_session.id
  end

  def mcp_require_session!
    @mcp_session = McpToolkit::Session.find(request.headers[SESSION_HEADER], config: mcp_config)
    mcp_render_session_not_found if @mcp_session.nil?
  end

  # ---- token + account extraction -------------------------------------

  # Token sources, highest priority first: Bearer header, legacy X-MCP-Token
  # header, then the `token` query param (the header-less client fallback).
  def mcp_extract_token
    auth_header = request.headers["Authorization"]
    return auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")

    request.headers["X-MCP-Token"].presence || params[:token].presence
  end

  # Account selector for a single call, highest priority first: params._meta key,
  # tools/call `account_id` argument, then the account-id header (request-wide
  # fallback). Key/header names come from config so a host on a specific authority
  # can match that authority's convention.
  def mcp_candidate_account_id(request_data)
    params = request_data.to_h["params"].to_h
    meta = params["_meta"].to_h
    arguments = params["arguments"].to_h

    meta[mcp_config.account_meta_key] ||
      arguments["account_id"] ||
      request.headers[mcp_config.account_id_header]
  end

  # ---- error renders --------------------------------------------------

  def mcp_render_unauthorized(message)
    render json: {
      jsonrpc: McpToolkit::Protocol::JSONRPC_VERSION,
      id: nil,
      error: {
        code: -32_000,
        message: "Unauthorized: #{message}"
      }
    }, status: :unauthorized
  end

  def mcp_render_session_not_found
    render json: {
      jsonrpc: McpToolkit::Protocol::JSONRPC_VERSION,
      id: nil,
      error: { code: -32_001, message: "Session not found or expired" }
    }, status: :not_found
  end

  # ---- body parsing ---------------------------------------------------

  def mcp_parse_body
    return @mcp_parsed_body if defined?(@mcp_parsed_body)

    @mcp_parsed_body = JSON.parse(request.body.read)
  rescue JSON::ParserError => e
    raise McpToolkit::Protocol::ParseError, "Invalid JSON: #{e.message}"
  end

  def mcp_methods_from(request_body)
    # Array.wrap (not Kernel#Array): a single JSON-RPC Hash must wrap to [hash],
    # whereas Kernel#Array(hash) would explode it into [[k, v], ...].
    Array.wrap(request_body).filter_map { |req| req.is_a?(Hash) ? req["method"] : nil }
  end
end
