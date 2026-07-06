# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Gateway::Client do
  subject(:client) { described_class.new(upstream:, bearer_token: "tok-123") }

  let(:upstream_url) { "http://notifications.test/mcp" }
  let(:upstream) do
    McpToolkit::Gateway::UpstreamRegistry::Upstream.new(key: "notifications", url: upstream_url)
  end

  # --- request stubs, routed by the JSON-RPC method in the POST body ---------

  def stub_initialize(session_id: "sess-1")
    stub_request(:post, upstream_url)
      .with(body: hash_including("method" => "initialize"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json", described_class::SESSION_HEADER => session_id },
        body: JSON.generate("jsonrpc" => "2.0", "id" => "x", "result" => { "protocolVersion" => "2025-06-18" })
      )
  end

  def stub_initialized
    stub_request(:post, upstream_url)
      .with(body: hash_including("method" => "notifications/initialized"))
      .to_return(status: 202, body: "")
  end

  def stub_method(method, *responses)
    stub_request(:post, upstream_url).with(body: hash_including("method" => method)).to_return(*responses)
  end

  def json_response(result)
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("jsonrpc" => "2.0", "id" => "x", "result" => result) }
  end

  def tools_payload
    [{ "name" => "list_items", "description" => "List items.", "inputSchema" => { "type" => "object" } }]
  end

  describe "#tools_list" do
    before do
      stub_initialize
      stub_initialized
    end

    it "handshakes, then returns the upstream's bare tools array" do
      stub_method("tools/list", json_response("tools" => tools_payload))

      expect(client.tools_list).to eq(tools_payload)
    end

    it "sends the genericized clientInfo (config identity, not a hardcoded app name)" do
      McpToolkit.config.server_name = "gateway-under-test"
      McpToolkit.config.server_version = "9.9.9"
      stub_method("tools/list", json_response("tools" => []))

      client.tools_list

      expect(a_request(:post, upstream_url).with { |req|
        JSON.parse(req.body)["params"]["clientInfo"] == { "name" => "gateway-under-test", "version" => "9.9.9" }
      }).to have_been_made
    end

    it "applies content-negotiation, auth and session headers on the list request" do
      stub_method("tools/list", json_response("tools" => tools_payload))

      client.tools_list

      expect(
        a_request(:post, upstream_url).with(
          body: hash_including("method" => "tools/list"),
          headers: {
            "Content-Type" => "application/json",
            "Accept" => "application/json, text/event-stream",
            "Authorization" => "Bearer tok-123",
            described_class::SESSION_HEADER => "sess-1"
          }
        )
      ).to have_been_made
    end

    it "unwraps a single SSE `data:` frame when the upstream answers text/event-stream" do
      sse_body = "event: message\ndata: #{JSON.generate("jsonrpc" => "2.0", "id" => "x",
                                                         "result" => { "tools" => tools_payload })}\n\n"
      stub_method(
        "tools/list",
        status: 200, headers: { "Content-Type" => "text/event-stream" }, body: sse_body
      )

      expect(client.tools_list).to eq(tools_payload)
    end
  end

  describe "#tools_call" do
    before do
      stub_initialize
      stub_initialized
    end

    it "forwards arguments and returns the upstream result verbatim" do
      stub_method("tools/call", json_response("content" => [{ "type" => "text", "text" => "ok" }]))

      result = client.tools_call(name: "list_items", arguments: { "q" => "hi" })

      expect(result).to eq("content" => [{ "type" => "text", "text" => "ok" }])
    end

    it "includes `_meta` in the params only when a meta hash is present" do
      stub_method("tools/call", json_response("content" => []))

      client.tools_call(name: "list_items", arguments: {}, meta: { "mcp-toolkit/account-id" => 42 })

      expect(a_request(:post, upstream_url).with { |req|
        JSON.parse(req.body)["params"]["_meta"] == { "mcp-toolkit/account-id" => 42 }
      }).to have_been_made
    end

    it "omits `_meta` when no meta is given" do
      stub_method("tools/call", json_response("content" => []))

      client.tools_call(name: "list_items", arguments: {})

      expect(a_request(:post, upstream_url).with { |req|
        parsed = JSON.parse(req.body)
        parsed["method"] == "tools/call" && !parsed["params"].key?("_meta")
      }).to have_been_made
    end
  end

  describe "error handling" do
    before do
      stub_initialize
      stub_initialized
    end

    it "raises Error carrying the upstream JSON-RPC error hash for verbatim relay" do
      stub_method(
        "tools/call",
        json_response(nil).merge(
          body: JSON.generate("jsonrpc" => "2.0", "id" => "x",
                               "error" => { "code" => -32_603, "message" => "boom", "data" => { "x" => 1 } })
        )
      )

      expect { client.tools_call(name: "list_items", arguments: {}) }
        .to raise_error(described_class::Error) do |e|
          expect(e.jsonrpc_error).to eq("code" => -32_603, "message" => "boom", "data" => { "x" => 1 })
          expect(e.http_status).to be_nil
        end
    end

    it "raises Error carrying http_status for a non-2xx (non-session-loss) response" do
      stub_method("tools/list", status: 500, body: "upstream exploded")

      expect { client.tools_list }.to raise_error(described_class::Error) do |e|
        expect(e.http_status).to eq(500)
        expect(e.jsonrpc_error).to be_nil
      end
    end

    it "raises Error on an unparseable body" do
      stub_method("tools/list", status: 200, headers: { "Content-Type" => "application/json" }, body: "not json{")

      expect { client.tools_list }.to raise_error(described_class::Error, /unparseable body/)
    end

    it "is an McpToolkit::Error (no transport/protocol coupling)" do
      expect(described_class::Error.ancestors).to include(McpToolkit::Error)
    end
  end

  describe "single-shot session-loss recovery" do
    it "recovers from a bare HTTP 404 by re-handshaking and retrying once" do
      stub_initialize
      stub_initialized
      stub_method(
        "tools/list",
        { status: 404, body: "gone" },
        json_response("tools" => tools_payload)
      )

      expect(client.tools_list).to eq(tools_payload)
      # initialize was performed twice: the original + the recovery handshake.
      expect(a_request(:post, upstream_url).with(body: hash_including("method" => "initialize")))
        .to have_been_made.twice
    end

    it "recovers from a JSON-RPC -32001 session error and retries once" do
      stub_initialize
      stub_initialized
      stub_method(
        "tools/call",
        json_response(nil).merge(
          body: JSON.generate("jsonrpc" => "2.0", "id" => "x",
                              "error" => { "code" => -32_001, "message" => "Session not found or expired" })
        ),
        json_response("content" => [{ "type" => "text", "text" => "recovered" }])
      )

      result = client.tools_call(name: "list_items", arguments: {})

      expect(result).to eq("content" => [{ "type" => "text", "text" => "recovered" }])
    end

    it "logs a warning via config.logger on recovery" do
      McpToolkit.config.logger = instance_double(Logger, warn: nil)
      stub_initialize
      stub_initialized
      stub_method("tools/list", { status: 404, body: "gone" }, json_response("tools" => tools_payload))

      client.tools_list

      expect(McpToolkit.config.logger).to have_received(:warn).with(/session lost.*re-initializing/)
    end

    it "clarifies the error when recovery also fails (second attempt still 404)" do
      stub_initialize
      stub_initialized
      stub_method("tools/list", { status: 404, body: "gone" }, { status: 404, body: "still gone" })

      expect { client.tools_list }.to raise_error(described_class::Error) do |e|
        expect(e.message).to match(/session was lost and could not be re-established/)
        expect(e.http_status).to eq(404)
      end
    end

    it "does NOT retry a genuine (non-session-loss) JSON-RPC error" do
      stub_initialize
      stub_initialized
      stub_method(
        "tools/list",
        json_response(nil).merge(
          body: JSON.generate("jsonrpc" => "2.0", "id" => "x",
                              "error" => { "code" => -32_603, "message" => "boom" })
        )
      )

      expect { client.tools_list }.to raise_error(described_class::Error, /boom/)
      # A single initialize: no recovery handshake for a non-session-loss error.
      expect(a_request(:post, upstream_url).with(body: hash_including("method" => "initialize")))
        .to have_been_made.once
    end
  end

  describe "DEFAULT_PROTOCOL_VERSION" do
    it "sources the wrapped mcp SDK's latest-supported version" do
      expect(described_class::DEFAULT_PROTOCOL_VERSION)
        .to eq(MCP::Configuration::LATEST_STABLE_PROTOCOL_VERSION)
    end

    it "offers config.protocol_version on the handshake when pinned" do
      McpToolkit.config.protocol_version = "2025-03-26"
      stub_initialize
      stub_initialized
      stub_method("tools/list", json_response("tools" => []))

      client.tools_list

      expect(a_request(:post, upstream_url).with { |req|
        JSON.parse(req.body)["params"]["protocolVersion"] == "2025-03-26"
      }).to have_been_made
    end
  end
end
