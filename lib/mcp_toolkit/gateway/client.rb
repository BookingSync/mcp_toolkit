# frozen_string_literal: true

require "faraday"

# Minimal MCP client over Streamable HTTP, used by a GATEWAY to talk to an
# upstream MCP server when aggregating its tool list and proxying tool calls.
#
# It speaks the same Streamable-HTTP MCP that McpToolkit::Transport serves:
#   1. POST `initialize`                 -> capture the `Mcp-Session-Id` response header
#   2. POST `notifications/initialized`  (a notification; no response expected)
#   3. POST `tools/list` / `tools/call`, echoing the session header
#
# Auth & account selection are pass-through: the caller's bearer token and the
# account selector (`_meta`) are forwarded so the upstream can introspect the
# same token against its authority and resolve the same account.
#
# Transport notes
#   - Content negotiation: we POST application/json and Accept both
#     application/json and text/event-stream. If the upstream answers with SSE
#     (one message + EOF, as the toolkit's own transport does) we extract the
#     single JSON payload from the `data:` line.
#   - Every public method may raise McpToolkit::Gateway::Client::Error (timeouts,
#     non-2xx, unparseable bodies, JSON-RPC errors). Callers decide whether to
#     degrade (omit from list) or surface the error (proxied call).
#
# Everything app-specific (server identity, protocol version, timeout, logger) is
# injected via McpToolkit::Configuration; nothing here names a deployment.
class McpToolkit::Gateway::Client
  SESSION_HEADER = "Mcp-Session-Id"
  JSONRPC_VERSION = "2.0"

  # The protocol version offered on the handshake when the config does not pin
  # one. Sourced from the wrapped `mcp` SDK's latest-supported constant when
  # available, with a literal fallback so the gem still loads if the SDK moves the
  # constant. `config.protocol_version` overrides it.
  DEFAULT_PROTOCOL_VERSION =
    if defined?(MCP::Configuration) && MCP::Configuration.const_defined?(:LATEST_STABLE_PROTOCOL_VERSION)
      MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION
    else
      "2025-06-18"
    end

  # An upstream whose session store is not shared across its pods can answer a
  # NON-initialize request with HTTP 404 (the pod fielding it never saw our
  # initialize), or with a JSON-RPC -32001 "Session not found or expired". Both
  # mean the same thing: our session is gone and a fresh handshake recovers it.
  SESSION_LOSS_HTTP_STATUS = 404
  SESSION_NOT_FOUND_CODE = -32_001

  # Raised for any upstream failure. `jsonrpc_error` carries an upstream JSON-RPC
  # error hash when the failure was a protocol-level error response, so a proxy
  # can relay it verbatim; nil for transport/HTTP failures. `http_status` carries
  # the HTTP status for a non-2xx response (nil otherwise), so callers can
  # distinguish a session-loss 404 from other failures. This class references NO
  # transport/protocol-error type — the consumer maps it.
  class Error < McpToolkit::Error
    attr_reader :jsonrpc_error, :http_status

    def initialize(message, jsonrpc_error: nil, http_status: nil)
      super(message)
      @jsonrpc_error = jsonrpc_error
      @http_status = http_status
    end
  end

  attr_reader :upstream, :bearer_token, :timeout, :config

  def initialize(upstream:, bearer_token: nil, config: McpToolkit.config)
    @upstream = upstream
    @bearer_token = bearer_token
    @config = config
    @timeout = config.upstream_timeout
    @session_id = nil
    @initialized = false
  end

  # Returns the upstream's raw tools array (each a tool definition hash with
  # string keys: "name", "description", "inputSchema"). Bare names — the caller
  # namespaces them.
  def tools_list
    with_session_recovery("tools/list") do
      result = rpc!("tools/list")
      Array(result["tools"])
    end
  end

  # Proxies a tools/call to the upstream. `arguments` and `meta` are forwarded
  # as-is. Returns the upstream's `result` hash verbatim (typically
  # `{ "content" => [...] }`). A JSON-RPC error from the upstream is raised as an
  # Error carrying `jsonrpc_error` so a proxy can relay it.
  def tools_call(name:, arguments: {}, meta: nil)
    params = { "name" => name, "arguments" => arguments }
    params["_meta"] = meta if meta.present?
    with_session_recovery("tools/call #{name}") do
      rpc!("tools/call", params)
    end
  end

  private

  # The protocol version to offer on the handshake: the config's pin, else the
  # gem's default.
  def protocol_version
    config.protocol_version || DEFAULT_PROTOCOL_VERSION
  end

  # Runs a request-bearing RPC against an initialized session, transparently
  # recovering from a SINGLE session-loss response: if the upstream reports our
  # session is gone (see SESSION_LOSS_HTTP_STATUS / SESSION_NOT_FOUND_CODE) we
  # drop the dead session, re-handshake, and retry the block exactly ONCE. Any
  # other error — a genuine JSON-RPC tool error, a timeout, a non-404 HTTP
  # failure — propagates verbatim, unchanged. An upstream tool that returns an
  # `isError` content result is a normal return value here (not an exception), so
  # it passes straight through.
  def with_session_recovery(operation, &)
    ensure_initialized!
    yield
  rescue Error => e
    raise unless session_loss?(e)

    recover_and_retry(operation, e, &)
  end

  # Second (and final) attempt after a session-loss signal: re-establish the
  # session and run the block once more. Bounded to one retry — this method does
  # not recurse into `with_session_recovery`, so it cannot loop. If re-init or the
  # retry itself fails, the error is clarified before it propagates.
  def recover_and_retry(operation, original_error)
    log_session_recovery(operation, original_error)
    reset_session!
    ensure_initialized!
    yield
  rescue Error => e
    raise clarified_session_error(e, operation)
  end

  # Performs the initialize handshake once per client instance, capturing the
  # session id, then sends the `notifications/initialized` notification.
  def ensure_initialized!
    return if @initialized

    response = post_jsonrpc(
      jsonrpc_request("initialize", {
                        "protocolVersion" => protocol_version,
                        "capabilities" => {},
                        "clientInfo" => { "name" => config.server_name, "version" => config.server_version }
                      })
    )
    @session_id = response.headers[SESSION_HEADER].presence
    parse_rpc_result!(response)

    # Best-effort lifecycle notification; upstreams may ignore it. A notification
    # returns no body (202), so we don't parse a result.
    post_jsonrpc(jsonrpc_notification("notifications/initialized"))

    @initialized = true
  end

  # Drops the current session so the next `ensure_initialized!` re-handshakes.
  def reset_session!
    @initialized = false
    @session_id = nil
  end

  # True when an upstream error signals our session is gone and a fresh handshake
  # could recover it: a bare HTTP 404, or a JSON-RPC -32001 session error.
  def session_loss?(error)
    error.http_status == SESSION_LOSS_HTTP_STATUS ||
      error.jsonrpc_error&.dig("code") == SESSION_NOT_FOUND_CODE
  end

  # A session-loss failure we could NOT recover from (already retried once).
  # Preserve verbatim relay for a genuine JSON-RPC error and pass through any
  # unrelated failure; only rewrite the bare "returned HTTP 404", whose message
  # hides the real cause.
  def clarified_session_error(error, operation)
    return error if error.jsonrpc_error
    return error unless session_loss?(error)

    Error.new(
      "upstream #{upstream.key} #{operation} failed: the MCP session was lost and could not " \
      "be re-established after re-initializing the handshake",
      http_status: error.http_status
    )
  end

  def log_session_recovery(operation, error)
    config.logger&.warn(
      "MCP upstream #{upstream.key} #{operation}: session lost (#{session_loss_reason(error)}), " \
      "re-initializing and retrying once"
    )
  end

  def session_loss_reason(error)
    return "JSON-RPC #{error.jsonrpc_error["code"]}" if error.jsonrpc_error
    return "HTTP #{error.http_status}" if error.http_status

    "unknown"
  end

  # Sends a request-bearing JSON-RPC call and returns its `result`.
  def rpc!(method, params = {})
    response = post_jsonrpc(jsonrpc_request(method, params))
    parse_rpc_result!(response)
  end

  def jsonrpc_request(method, params = {})
    { "jsonrpc" => JSONRPC_VERSION, "id" => SecureRandom.uuid, "method" => method, "params" => params }
  end

  def jsonrpc_notification(method, params = {})
    { "jsonrpc" => JSONRPC_VERSION, "method" => method, "params" => params }
  end

  def post_jsonrpc(body)
    connection.post(upstream.url) do |request|
      apply_request_headers(request.headers)
      request.body = JSON.generate(body)
    end
  rescue Faraday::TimeoutError => e
    raise upstream_error("timed out after #{timeout}s", e)
  rescue Faraday::Error => e
    raise upstream_error("request failed", e)
  end

  def upstream_error(reason, cause)
    Error.new("upstream #{upstream.key} #{reason}: #{cause.message}")
  end

  # Sets the content-negotiation, auth, and session headers on an outgoing
  # request. Auth and session headers are added only when present.
  def apply_request_headers(headers)
    headers["Content-Type"] = "application/json"
    headers["Accept"] = "application/json, text/event-stream"
    headers["Authorization"] = "Bearer #{bearer_token}" if bearer_token.present?
    headers[SESSION_HEADER] = @session_id if @session_id.present?
  end

  # Validates the HTTP response and extracts the JSON-RPC `result`, raising on a
  # JSON-RPC error (with the error hash attached for verbatim relay).
  def parse_rpc_result!(response)
    raise_http_error!(response) unless response.success?

    payload = decode_body(response)
    return {} if payload.nil? # e.g. 202 Accepted for a notification

    if payload["error"]
      raise Error.new(
        "upstream #{upstream.key} JSON-RPC error: #{payload.dig("error", "message")}",
        jsonrpc_error: payload["error"]
      )
    end

    payload["result"] || {}
  end

  # The `http_status` is carried on the Error so a session-loss 404 can be told
  # apart from other non-2xx failures (see `session_loss?`).
  def raise_http_error!(response)
    raise Error.new("upstream #{upstream.key} returned HTTP #{response.status}", http_status: response.status)
  end

  # Decodes either a plain JSON body or a single SSE `data:` frame.
  def decode_body(response)
    json = json_payload(response)
    return nil if json.nil?

    JSON.parse(json)
  rescue JSON::ParserError => e
    raise Error, "upstream #{upstream.key} returned unparseable body: #{e.message}"
  end

  # Extracts the JSON text to parse, unwrapping an SSE frame when the response is
  # an event stream. Returns nil for an empty body or an empty/absent frame.
  def json_payload(response)
    body = response.body.to_s
    return nil if body.strip.empty?

    content_type = response.headers["Content-Type"].to_s
    json = content_type.include?("text/event-stream") ? extract_sse_data(body) : body
    json unless json.nil? || json.strip.empty?
  end

  # Pulls the JSON payload from the first `data:` line of an SSE stream.
  def extract_sse_data(body)
    body.each_line.filter_map do |line|
      line.start_with?("data:") ? line.sub(/\Adata:\s?/, "").chomp : nil
    end.first
  end

  def connection
    @connection ||= Faraday.new do |conn|
      conn.options.timeout = timeout
      conn.options.open_timeout = timeout
      conn.adapter Faraday.default_adapter
    end
  end
end
