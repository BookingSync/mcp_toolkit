# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

# The transport concern runs WITHOUT Rails in the gem's suite, so this exercises
# the session-not-found path against a minimal host class that provides only the
# class hooks the concern's `included do` block invokes (`before_action`; CSRF is
# guarded behind respond_to? and thus skipped). `request` / `response` / `render`
# are stubbed to the slice the method touches.
RSpec.describe McpToolkit::Transport::ControllerMethods do
  let(:log_output) { StringIO.new }
  let(:logger) { Logger.new(log_output) }

  let(:controller_class) do
    Class.new do
      def self.before_action(*); end
      include McpToolkit::Transport::ControllerMethods

      attr_accessor :session_header_value
      attr_reader :rendered

      def request
        headers = { McpToolkit::Transport::ControllerMethods::SESSION_HEADER => session_header_value }
        Struct.new(:headers).new(headers)
      end

      def render(*args)
        @rendered = args
      end
    end
  end

  let(:controller) { controller_class.new }

  describe "#mcp_render_session_not_found logging (P3)" do
    it "warns with a greppable, id-free message when a session is not found" do
      controller.session_header_value = "sess-secret-123"
      allow(controller).to receive(:mcp_logger).and_return(logger)

      controller.send(:mcp_render_session_not_found)

      expect(log_output.string).to include("[McpToolkit] MCP session not found or expired")
      expect(log_output.string).to include("header present: true")
      expect(log_output.string).to include("cache_store")
      expect(log_output.string).not_to include("sess-secret-123")
    end

    it "reports header present: false when no session-id header was sent" do
      controller.session_header_value = nil
      allow(controller).to receive(:mcp_logger).and_return(logger)

      controller.send(:mcp_render_session_not_found)

      expect(log_output.string).to include("header present: false")
    end

    it "still renders the -32001 not-found JSON-RPC error after logging" do
      controller.session_header_value = "sess-123"
      allow(controller).to receive(:mcp_logger).and_return(logger)

      controller.send(:mcp_render_session_not_found)

      payload = controller.rendered.first
      expect(payload).to include(status: :not_found)
      expect(payload[:json][:error][:code]).to eq(-32_001)
    end

    it "is a no-op (does not raise) when no logger is available, e.g. Rails absent" do
      controller.session_header_value = "sess-123"

      expect { controller.send(:mcp_render_session_not_found) }.not_to raise_error
      expect(controller.rendered.first).to include(status: :not_found)
    end
  end
end
