# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Gateway::Proxy do
  subject(:proxy) do
    described_class.new(app_key: "notifications", tool_name: "send_email", account_id: 42, bearer_token: "caller_tok")
  end

  let(:client) { instance_double(McpToolkit::Gateway::Client) }
  let(:upstream) { McpToolkit.config.upstreams.find("notifications") }

  before do
    McpToolkit.config.register_upstream(key: "notifications", url: "https://notif.test/mcp")
    allow(McpToolkit::Gateway::Client).to receive(:new).and_return(client)
  end

  describe "#call" do
    it "forwards bearer, resolved account_id (as _meta) and arguments, returning the result verbatim" do
      allow(client).to receive(:tools_call).and_return("content" => [{ "type" => "text", "text" => "ok" }])

      result = proxy.call({ "to" => "a@b.c" })

      expect(result).to eq("content" => [{ "type" => "text", "text" => "ok" }])
      expect(McpToolkit::Gateway::Client)
        .to have_received(:new).with(upstream:, bearer_token: "caller_tok", config: McpToolkit.config)
      expect(client).to have_received(:tools_call).with(
        name: "send_email",
        arguments: { "to" => "a@b.c" },
        meta: { "mcp-toolkit/account-id" => 42 }
      )
    end

    it "uses the configured account_meta_key for the _meta selector" do
      McpToolkit.config.account_meta_key = "example.com/account-id"
      allow(client).to receive(:tools_call).and_return("content" => [])

      proxy.call({})

      expect(client).to have_received(:tools_call)
        .with(hash_including(meta: { "example.com/account-id" => 42 }))
    end

    it "omits _meta entirely when no account_id is supplied" do
      no_account = described_class.new(app_key: "notifications", tool_name: "send_email", bearer_token: "t")
      allow(client).to receive(:tools_call).and_return("content" => [])

      no_account.call({})

      expect(client).to have_received(:tools_call).with(hash_including(meta: nil))
    end

    it "raises UnknownUpstream for an unregistered app_key (no protocol coupling)" do
      unknown = described_class.new(app_key: "ghost", tool_name: "x")

      expect { unknown.call({}) }
        .to raise_error(McpToolkit::Gateway::UnknownUpstream, /Unknown application: ghost/)
    end
  end

  describe "error relay" do
    it "re-raises a JSON-RPC upstream error as UpstreamCallError carrying jsonrpc_error" do
      allow(client).to receive(:tools_call).and_raise(
        McpToolkit::Gateway::Client::Error.new("upstream error", jsonrpc_error: { "code" => -32_602, "message" => "bad" })
      )

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError) do |e|
        expect(e.jsonrpc_error).to eq("code" => -32_602, "message" => "bad")
        expect(e.http_status).to be_nil
      end
    end

    it "re-raises a transport failure as UpstreamCallError carrying http_status" do
      allow(client).to receive(:tools_call).and_raise(
        McpToolkit::Gateway::Client::Error.new("upstream notifications timed out", http_status: 404)
      )

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError) do |e|
        expect(e.http_status).to eq(404)
        expect(e.jsonrpc_error).to be_nil
      end
    end

    it "does NOT translate to any JSON-RPC / protocol error class (consumer maps it)" do
      expect(McpToolkit::Gateway::UpstreamCallError.ancestors).to include(McpToolkit::Error)
      expect(McpToolkit::Gateway::UnknownUpstream.ancestors).to include(McpToolkit::Error)
    end
  end

  describe "failure logging (greppable, never a token or a body)" do
    let(:logger) { instance_double(Logger, error: nil) }

    before { McpToolkit.config.logger = logger }

    it "logs a proxied-call failure at ERROR with the upstream key, tool, and HTTP status" do
      allow(client).to receive(:tools_call).and_raise(
        McpToolkit::Gateway::Client::Error.new("upstream notifications tools/call send_email failed", http_status: 404)
      )

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError)

      expect(logger).to have_received(:error)
        .with(a_string_including("MCP upstream notifications tools/call send_email failed", "http_status=404"))
    end

    it "logs a relayed JSON-RPC error at ERROR with its code" do
      allow(client).to receive(:tools_call).and_raise(
        McpToolkit::Gateway::Client::Error.new("upstream error", jsonrpc_error: { "code" => -32_602, "message" => "bad" })
      )

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError)

      expect(logger).to have_received(:error).with(a_string_including("jsonrpc_code=-32602"))
    end

    it "never includes the bearer token in the log line" do
      allow(client).to receive(:tools_call).and_raise(McpToolkit::Gateway::Client::Error.new("boom"))

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError)

      expect(logger).to have_received(:error).with(satisfy { |line| !line.include?("caller_tok") })
    end

    it "does not require a logger (config.logger defaults to nil)" do
      McpToolkit.config.logger = nil
      allow(client).to receive(:tools_call).and_raise(McpToolkit::Gateway::Client::Error.new("boom"))

      expect { proxy.call({}) }.to raise_error(McpToolkit::Gateway::UpstreamCallError)
    end
  end
end
