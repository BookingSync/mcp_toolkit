# frozen_string_literal: true

require "spec_helper"

# Ported from core's protocol_spec: the byte contract of the JSON-RPC envelope +
# error codes the authority dispatcher emits.
RSpec.describe McpToolkit::Protocol do
  describe "SUPPORTED_VERSIONS" do
    it "lists the protocol versions the server can negotiate, newest first" do
      expect(described_class::SUPPORTED_VERSIONS).to eq(%w[2025-06-18 2025-03-26 2024-11-05])
      expect(described_class::LATEST_VERSION).to eq("2025-06-18")
      expect(described_class::VERSION).to eq(described_class::LATEST_VERSION)
    end
  end

  describe "JSONRPC_VERSION" do
    it "returns the JSON-RPC version" do
      expect(described_class::JSONRPC_VERSION).to eq("2.0")
    end
  end

  describe "ErrorCodes" do
    it "pins the JSON-RPC 2.0 codes" do
      expect(described_class::ErrorCodes::PARSE_ERROR).to eq(-32_700)
      expect(described_class::ErrorCodes::INVALID_REQUEST).to eq(-32_600)
      expect(described_class::ErrorCodes::METHOD_NOT_FOUND).to eq(-32_601)
      expect(described_class::ErrorCodes::INVALID_PARAMS).to eq(-32_602)
      expect(described_class::ErrorCodes::INTERNAL_ERROR).to eq(-32_603)
    end
  end

  describe ".success_response" do
    it "returns a properly formatted success response" do
      expect(described_class.success_response(id: 1, result: { foo: "bar" })).to eq(
        jsonrpc: "2.0", id: 1, result: { foo: "bar" }
      )
    end
  end

  describe ".error_response" do
    it "formats an Error object via #to_h" do
      error = described_class::InternalError.new("Something went wrong")

      expect(described_class.error_response(id: 1, error:)).to eq(
        jsonrpc: "2.0", id: 1, error: { code: -32_603, message: "Something went wrong" }
      )
    end

    it "passes a raw hash error through as-is" do
      error = { code: -32_000, message: "Custom error" }

      expect(described_class.error_response(id: 1, error:)).to eq(
        jsonrpc: "2.0", id: 1, error: { code: -32_000, message: "Custom error" }
      )
    end
  end

  describe McpToolkit::Protocol::Error do
    subject(:error) { described_class.new("Test error", code: -32_000, data: { extra: "info" }) }

    it "exposes message, code and data" do
      expect(error.message).to eq("Test error")
      expect(error.code).to eq(-32_000)
      expect(error.data).to eq(extra: "info")
    end

    it "serializes to a hash, including data when present" do
      expect(error.to_h).to eq(code: -32_000, message: "Test error", data: { extra: "info" })
    end

    it "omits the data key when absent" do
      expect(described_class.new("Test error", code: -32_000).to_h).to eq(code: -32_000, message: "Test error")
    end
  end

  describe "the error subclasses carry their own code + default message" do
    it "ParseError" do
      error = McpToolkit::Protocol::ParseError.new
      expect([error.code, error.message]).to eq([-32_700, "Parse error"])
    end

    it "InvalidRequest" do
      error = McpToolkit::Protocol::InvalidRequest.new
      expect([error.code, error.message]).to eq([-32_600, "Invalid request"])
    end

    it "MethodNotFound embeds the method name" do
      error = McpToolkit::Protocol::MethodNotFound.new("unknown_method")
      expect([error.code, error.message]).to eq([-32_601, "Method not found: unknown_method"])
    end

    it "InvalidParams" do
      error = McpToolkit::Protocol::InvalidParams.new
      expect([error.code, error.message]).to eq([-32_602, "Invalid params"])
    end

    it "InternalError" do
      error = McpToolkit::Protocol::InternalError.new
      expect([error.code, error.message]).to eq([-32_603, "Internal error"])
    end
  end
end
