# frozen_string_literal: true

# Hand-rolled JSON-RPC dispatcher for the AUTHORITY + gateway path: it handles a
# single JSON-RPC request (one element of a batch), serving the host's own tools
# and, as a gateway, aggregating + proxying upstream MCP servers — WITHOUT the
# official `mcp` SDK in the request path.
#
# The gem carries two dispatch front-ends by design (see McpToolkit::Protocol):
# this Dispatcher for the authority/gateway endpoint, and McpToolkit::Server.build
# (the SDK wrapper) for satellites. They are independent; nothing here touches the
# satellite path.
#
# Everything host-specific is injected:
#   * `context`  — an McpToolkit::Authority::Context (the resolved account, the
#                  authenticated principal, and the bearer token to forward
#                  upstream). Re-created PER JSON-RPC request by the transport, so
#                  each batch element carries its own account.
#   * `config`   — server identity (`server_name`/`server_version`), the
#                  negotiable protocol versions, the registered `upstreams`, and
#                  the `tool_provider` (the host's api-agnostic tool catalog).
#
# The wire behavior — top-level JSON-RPC tool-error codes, `initialize`
# capabilities `{ tools: { listChanged: true } }`, 3-version negotiation, verbatim
# upstream error relay, and the custom `notifications/<app>/tools/list_changed`
# cache-bust — is the byte contract of a first-party endpoint and is preserved
# exactly.
class McpToolkit::Dispatcher
  attr_reader :context, :config

  def initialize(context:, config: McpToolkit.config)
    @context = context
    @config = config
  end

  def handle_request(request)
    dispatch_request(request)
  rescue McpToolkit::Protocol::Error => e
    return nil unless request.key?("id")

    McpToolkit::Protocol.error_response(id: request["id"], error: e)
  rescue StandardError => e
    config.logger&.error("MCP dispatcher error: #{e.message}\n#{e.backtrace&.join("\n")}")
    return nil unless request.key?("id")

    McpToolkit::Protocol.error_response(
      id: request["id"],
      error: McpToolkit::Protocol::InternalError.new(e.message)
    )
  end

  private

  # Happy path; raises here are turned into JSON-RPC errors by handle_request.
  def dispatch_request(request)
    validate_request!(request)

    result = dispatch_method(request["method"], request["params"] || {})

    # JSON-RPC 2.0: notifications (requests without `id`) MUST NOT receive a response.
    return nil unless request.key?("id")

    McpToolkit::Protocol.success_response(id: request["id"], result:)
  end

  def validate_request!(request)
    unless request["jsonrpc"] == McpToolkit::Protocol::JSONRPC_VERSION
      raise McpToolkit::Protocol::InvalidRequest, "Missing jsonrpc version"
    end
    raise McpToolkit::Protocol::InvalidRequest, "Missing method" if request["method"].blank?
  end

  def dispatch_method(method, params)
    case method
    when "initialize"
      handle_initialize(params)
    when "initialized", "notifications/initialized"
      handle_initialized
    when "tools/list"
      handle_tools_list
    when "tools/call"
      handle_tools_call(params)
    when "ping"
      handle_ping
    else
      return handle_upstream_list_changed(method) if upstream_list_changed_notification?(method)

      raise McpToolkit::Protocol::MethodNotFound, method
    end
  end

  # Satellites can tell the authority their tool list changed via a
  # `notifications/<app>/tools/list_changed` notification, busting that upstream's
  # cached aggregate. Matches the configured upstream keys only.
  def upstream_list_changed_notification?(method)
    upstream_key_from_notification(method).present?
  end

  def handle_upstream_list_changed(method)
    McpToolkit::Gateway::Aggregator.new(config:).flush!(upstream_key_from_notification(method))
    {}
  end

  def upstream_key_from_notification(method)
    match = method.to_s.match(%r{\Anotifications/(?<key>.+)/tools/list_changed\z})
    return nil unless match

    config.upstreams.find(match[:key]) ? match[:key] : nil
  end

  def handle_initialize(params)
    requested = params["protocolVersion"].to_s
    versions = config.supported_protocol_versions
    negotiated = versions.include?(requested) ? requested : versions.first

    {
      protocolVersion: negotiated,
      capabilities: {
        # listChanged: true — the aggregated list includes upstream tools, which
        # can change when an upstream is reconfigured or sends a list_changed
        # notification that busts the cached aggregate.
        tools: { listChanged: true }
      },
      serverInfo: {
        name: config.server_name,
        version: config.server_version
      }
    }
  end

  def handle_initialized
    {}
  end

  def handle_ping
    {}
  end

  def handle_tools_list
    {
      tools: host_tool_definitions +
        McpToolkit::Gateway::Aggregator.new(config:).tool_definitions(bearer_token: context.bearer_token)
    }
  end

  # The host's own tool definitions, sourced from the injected tool_provider (the
  # api-agnostic seam). `context` lets the provider hide superuser-only tools from
  # a non-superuser caller. A host that registered no provider contributes none.
  def host_tool_definitions
    provider = config.tool_provider
    return [] unless provider

    provider.tool_definitions(context)
  end

  def handle_tools_call(params)
    tool_name = params["name"]
    arguments = params["arguments"] || {}

    upstream = config.upstreams.split_tool_name(tool_name)
    return handle_upstream_tools_call(upstream, arguments) if upstream

    handle_host_tools_call(tool_name, arguments)
  end

  def handle_host_tools_call(tool_name, arguments)
    tool = config.tool_provider&.find(tool_name)
    raise McpToolkit::Protocol::MethodNotFound, "Tool not found: #{tool_name}" unless tool

    ensure_tool_scope!(tool)

    result = tool.call(context:, **symbolized_arguments(arguments))

    {
      content: [
        {
          type: "text",
          text: result.is_a?(String) ? result : result.to_json
        }
      ]
    }
  end

  # JSON gives string keys; a tool's `call(context:, **arguments)` needs symbol
  # keys for the keyword splat. Deep-symbolized so nested argument hashes reach
  # the tool in the same shape a symbol-keyed caller would pass.
  def symbolized_arguments(arguments)
    arguments.to_h.deep_symbolize_keys
  end

  def ensure_tool_scope!(tool)
    required_scope = tool.required_permissions_scope
    return if required_scope.blank?
    return if context.principal&.authorized_for_scope?(required_scope)

    raise McpToolkit::Protocol::InvalidRequest, "This token lacks the #{required_scope.inspect} scope"
  end

  def handle_upstream_tools_call((app_key, bare_tool_name), arguments)
    McpToolkit::Gateway::Proxy.new(
      app_key:,
      tool_name: bare_tool_name,
      account_id: context.account&.id,
      bearer_token: context.bearer_token,
      config:
    ).call(arguments)
  rescue McpToolkit::Gateway::UnknownUpstream => e
    # The gateway stays transport-agnostic; the dispatcher maps an unknown
    # upstream to its own "method not found".
    raise McpToolkit::Protocol::MethodNotFound, e.message
  rescue McpToolkit::Gateway::UpstreamCallError => e
    raise translate_upstream_call_error(e)
  end

  # Translates the gateway's transport-agnostic upstream failure into the JSON-RPC
  # error shape — verbatim relay of a satellite JSON-RPC error, else a generic
  # internal error.
  def translate_upstream_call_error(error)
    if error.jsonrpc_error
      McpToolkit::Protocol::Error.new(
        error.jsonrpc_error["message"].to_s,
        code: error.jsonrpc_error["code"] || McpToolkit::Protocol::ErrorCodes::INTERNAL_ERROR,
        data: error.jsonrpc_error["data"]
      )
    else
      McpToolkit::Protocol::InternalError.new(error.message)
    end
  end
end
