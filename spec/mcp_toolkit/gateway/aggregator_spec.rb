# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Gateway::Aggregator do
  subject(:aggregator) { described_class.new }

  let(:client) { instance_double(McpToolkit::Gateway::Client) }
  let(:tools) do
    [{ "name" => "send_email", "description" => "Send", "inputSchema" => { "type" => "object" } }]
  end

  before do
    McpToolkit.config.register_upstream(key: "notifications", url: "https://notif.test/mcp")
    allow(McpToolkit::Gateway::Client).to receive(:new).and_return(client)
    allow(client).to receive(:tools_list).and_return(tools)
  end

  describe "#tool_definitions" do
    it "namespaces each upstream tool as <app>__<tool>" do
      expect(aggregator.tool_definitions).to eq([
        { "name" => "notifications__send_email", "description" => "Send", "inputSchema" => { "type" => "object" } }
      ])
    end

    it "forwards the bearer token to the client (used on a cache miss)" do
      aggregator.tool_definitions(bearer_token: "tok-9")

      expect(McpToolkit::Gateway::Client)
        .to have_received(:new).with(hash_including(bearer_token: "tok-9"))
    end

    it "caches a non-empty pull (a second call does not hit the upstream)" do
      aggregator.tool_definitions
      aggregator.tool_definitions

      expect(client).to have_received(:tools_list).once
    end

    it "writes the namespaced list to config.cache_store under the gateway key" do
      aggregator.tool_definitions

      cached = McpToolkit.config.cache_store.read("#{described_class::CACHE_KEY_PREFIX}notifications")
      expect(cached).to eq([
        { "name" => "notifications__send_email", "description" => "Send", "inputSchema" => { "type" => "object" } }
      ])
    end

    context "when .flush! has been called" do
      it "pulls live again" do
        aggregator.tool_definitions
        aggregator.flush!
        aggregator.tool_definitions

        expect(client).to have_received(:tools_list).twice
      end

      it "flushes only the named upstream when a key is given" do
        aggregator.tool_definitions
        aggregator.flush!("notifications")
        aggregator.tool_definitions

        expect(client).to have_received(:tools_list).twice
      end
    end

    context "when the upstream list pull fails" do
      before do
        allow(client).to receive(:tools_list).and_raise(McpToolkit::Gateway::Client::Error.new("down"))
      end

      it "omits that upstream's tools instead of erroring the whole list" do
        expect(aggregator.tool_definitions).to eq([])
      end

      it "does not cache the failure (retries on the next call)" do
        aggregator.tool_definitions
        aggregator.tool_definitions

        expect(client).to have_received(:tools_list).twice
      end

      it "logs the degrade via config.logger when one is set" do
        McpToolkit.config.logger = instance_double(Logger, error: nil)

        aggregator.tool_definitions

        expect(McpToolkit.config.logger)
          .to have_received(:error).with(/upstream notifications tools\/list failed, omitting/)
      end

      it "does not require a logger (config.logger defaults to nil)" do
        expect { aggregator.tool_definitions }.not_to raise_error
      end
    end

    context "when the upstream list pull returns empty (a transient blip, not an error)" do
      before { allow(client).to receive(:tools_list).and_return([]) }

      it "omits that upstream's tools" do
        expect(aggregator.tool_definitions).to eq([])
      end

      it "does not cache the empty list, so a poisoned global cache cannot persist" do
        aggregator.tool_definitions
        aggregator.tool_definitions

        expect(client).to have_received(:tools_list).twice
      end

      it "self-heals: once the upstream returns tools they are served (and cached)" do
        aggregator.tool_definitions # empty pull, not cached

        allow(client).to receive(:tools_list).and_return(tools)

        expect(aggregator.tool_definitions).to eq([
          { "name" => "notifications__send_email", "description" => "Send", "inputSchema" => { "type" => "object" } }
        ])
      end
    end

    context "with a stale EMPTY entry already in the cache" do
      it "treats it as a miss and re-pulls (self-heal from a previously poisoned entry)" do
        McpToolkit.config.cache_store.write("#{described_class::CACHE_KEY_PREFIX}notifications", [])

        expect(aggregator.tool_definitions).to eq([
          { "name" => "notifications__send_email", "description" => "Send", "inputSchema" => { "type" => "object" } }
        ])
        expect(client).to have_received(:tools_list).once
      end
    end

    context "across multiple upstreams" do
      it "aggregates all upstreams' tools in registry order" do
        McpToolkit.config.register_upstream(key: "billing", url: "https://billing.test/mcp")
        allow(McpToolkit::Gateway::Client).to receive(:new) do |upstream:, **|
          instance_double(McpToolkit::Gateway::Client).tap do |c|
            allow(c).to receive(:tools_list).and_return(
              [{ "name" => "#{upstream.key}_tool", "description" => "d", "inputSchema" => {} }]
            )
          end
        end

        names = aggregator.tool_definitions.map { |d| d["name"] }
        expect(names).to eq(%w[notifications__notifications_tool billing__billing_tool])
      end
    end
  end
end
