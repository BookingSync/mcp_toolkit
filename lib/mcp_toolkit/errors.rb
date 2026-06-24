# frozen_string_literal: true

module McpToolkit
  # Tool-level errors raised by executors / auth and caught at the tool boundary,
  # where they are turned into an `isError: true` MCP tool result (NOT a JSON-RPC
  # protocol error). This matches how MCP clients (and a gateway relaying the
  # satellite's `result` verbatim) expect tool failures to surface: the call
  # succeeds at the protocol level, the result carries the error.
  module Errors
    class Base < StandardError; end

    # The arguments to a tool were invalid (missing id, unknown resource, bad
    # account selection, etc.).
    class InvalidParams < Base; end

    # The caller is not authenticated / authorized (token invalid, expired, lacks
    # the required application scope, or no/invalid account context).
    class Unauthorized < Base; end

    # The toolkit was used before it was configured, or a required piece of
    # configuration is missing for the operation being attempted.
    class ConfigurationError < Base; end
  end
end
