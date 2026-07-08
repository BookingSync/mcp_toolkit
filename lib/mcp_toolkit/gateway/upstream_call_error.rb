# frozen_string_literal: true

# Raised by McpToolkit::Gateway::Proxy when a proxied `tools/call` fails at the
# upstream. It carries the upstream failure detail so the CONSUMER can decide how
# to surface it:
#
#   * `jsonrpc_error` — the upstream's JSON-RPC error hash when the failure was a
#     protocol-level error response (so the consumer can relay it verbatim); nil
#     for transport/HTTP failures.
#   * `http_status`   — the HTTP status for a non-2xx response (nil otherwise).
#
# The gem deliberately does NOT map this to a protocol/transport error class:
# that mapping lives in the consuming dispatcher, keeping the gateway
# transport-agnostic.
class McpToolkit::Gateway::UpstreamCallError < McpToolkit::Error
  attr_reader :jsonrpc_error, :http_status

  def initialize(message, jsonrpc_error: nil, http_status: nil)
    super(message)
    @jsonrpc_error = jsonrpc_error
    @http_status = http_status
  end
end
