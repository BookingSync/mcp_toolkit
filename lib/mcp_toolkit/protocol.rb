# frozen_string_literal: true

# MCP JSON-RPC protocol constants + helpers for the hand-rolled AUTHORITY
# dispatcher (McpToolkit::Dispatcher). Based on the Model Context Protocol
# specification.
#
# This is the wire vocabulary of a first-party MCP endpoint that serves its own
# tools (and, as a gateway, aggregates upstream ones) WITHOUT the official `mcp`
# SDK in the request path. The SDK-backed satellite path
# (McpToolkit::Server.build) does not use this module; the two dispatch
# front-ends coexist by design.
#
# The error codes, the success/error response envelopes, and the
# version-negotiation constants here are the BYTE contract a monetized authority
# endpoint depends on, so they are kept fixed. `SUPPORTED_VERSIONS` is the module
# default; a host negotiates against `config.supported_protocol_versions`
# (defaulting to the same list) so the set is overridable without editing this
# file.
module McpToolkit::Protocol
  # Protocol versions the server supports, newest first. The version returned in
  # the `initialize` response is the requested version (if supported) or the
  # latest the server supports, per the MCP spec's version-negotiation rules.
  SUPPORTED_VERSIONS = %w[2025-06-18 2025-03-26 2024-11-05].freeze
  LATEST_VERSION = SUPPORTED_VERSIONS.first
  # Kept for backwards compatibility; prefer LATEST_VERSION going forward.
  VERSION = LATEST_VERSION

  JSONRPC_VERSION = "2.0"

  # Error codes per JSON-RPC 2.0 spec.
  module ErrorCodes
    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602
    INTERNAL_ERROR = -32_603
  end

  # Base protocol error. `code`/`data` land verbatim in the JSON-RPC `error`
  # object via `#to_h`; the dispatcher turns a raised Error into a top-level
  # JSON-RPC error response (the envelope a client sees for a bad tool arg or an
  # unknown method).
  class Error < StandardError
    attr_reader :code, :data

    def initialize(message, code:, data: nil)
      super(message)
      @code = code
      @data = data
    end

    def to_h
      error = { code:, message: }
      error[:data] = data if data
      error
    end
  end

  class ParseError < Error
    def initialize(message = "Parse error", data: nil)
      super(message, code: ErrorCodes::PARSE_ERROR, data:)
    end
  end

  class InvalidRequest < Error
    def initialize(message = "Invalid request", data: nil)
      super(message, code: ErrorCodes::INVALID_REQUEST, data:)
    end
  end

  class MethodNotFound < Error
    def initialize(method_name, data: nil)
      super("Method not found: #{method_name}", code: ErrorCodes::METHOD_NOT_FOUND, data:)
    end
  end

  class InvalidParams < Error
    def initialize(message = "Invalid params", data: nil)
      super(message, code: ErrorCodes::INVALID_PARAMS, data:)
    end
  end

  class InternalError < Error
    def initialize(message = "Internal error", data: nil)
      super(message, code: ErrorCodes::INTERNAL_ERROR, data:)
    end
  end

  module_function

  def success_response(id:, result:)
    {
      jsonrpc: JSONRPC_VERSION,
      id:,
      result:
    }
  end

  def error_response(id:, error:)
    {
      jsonrpc: JSONRPC_VERSION,
      id:,
      error: error.is_a?(Error) ? error.to_h : error
    }
  end
end
