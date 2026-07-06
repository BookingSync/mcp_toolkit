# frozen_string_literal: true

# Proxies a namespaced upstream tool call (`<app>__<tool>`) to its upstream MCP
# server.
#
# The account selector is forwarded as `_meta[config.account_meta_key]` when an
# `account_id` is supplied. The caller passes the already-resolved account id (a
# scalar), not a domain object — resolving the tenant is the consumer's job.
#
# Error mapping is deliberately thin and transport-agnostic:
#   * an unregistered `app_key` raises McpToolkit::Gateway::UnknownUpstream;
#   * an upstream call failure is re-raised as McpToolkit::Gateway::UpstreamCallError
#     carrying the upstream's `jsonrpc_error` / `http_status`.
# Neither is mapped to a JSON-RPC/protocol error class here — the consuming
# dispatcher does that at its call site.
class McpToolkit::Gateway::Proxy
  attr_reader :app_key, :tool_name, :account_id, :bearer_token, :config

  def initialize(app_key:, tool_name:, account_id: nil, bearer_token: nil, config: McpToolkit.config)
    @app_key = app_key
    @tool_name = tool_name
    @account_id = account_id
    @bearer_token = bearer_token
    @config = config
  end

  def call(arguments)
    upstream = config.upstreams.find(app_key)
    raise McpToolkit::Gateway::UnknownUpstream, "Unknown application: #{app_key}" if upstream.nil?

    client = McpToolkit::Gateway::Client.new(upstream:, bearer_token:, config:)
    client.tools_call(name: tool_name, arguments:, meta:)
  rescue McpToolkit::Gateway::Client::Error => e
    relay_upstream_error(e)
  end

  private

  def relay_upstream_error(error)
    log_proxied_failure(error)

    raise McpToolkit::Gateway::UpstreamCallError.new(
      error.message,
      jsonrpc_error: error.jsonrpc_error,
      http_status: error.http_status
    )
  end

  # Emit one concise, greppable ERROR line per failed proxied call — never a
  # bearer token or a full response body.
  def log_proxied_failure(error)
    config.logger&.error(
      "MCP upstream #{app_key} tools/call #{tool_name} failed#{failure_detail(error)}: #{error.message}"
    )
  end

  def failure_detail(error)
    code = error.jsonrpc_error&.dig("code")
    return " (jsonrpc_code=#{code})" if code
    return " (http_status=#{error.http_status})" if error.http_status

    ""
  end

  def meta
    return nil if account_id.nil?

    { config.account_meta_key => account_id }
  end
end
