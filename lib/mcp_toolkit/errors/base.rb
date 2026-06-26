# frozen_string_literal: true

# Tool-level errors raised by executors / auth and caught at the tool boundary,
# where they are turned into an `isError: true` MCP tool result (NOT a JSON-RPC
# protocol error). This matches how MCP clients (and a gateway relaying the
# satellite's `result` verbatim) expect tool failures to surface: the call
# succeeds at the protocol level, the result carries the error.
#
# Base class for that family; subclasses below narrow the cause.
class McpToolkit::Errors::Base < StandardError; end
