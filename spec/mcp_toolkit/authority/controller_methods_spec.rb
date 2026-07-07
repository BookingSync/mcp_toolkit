# frozen_string_literal: true

require "spec_helper"
require "stringio"

# The authority transport concern runs WITHOUT Rails in the gem's suite, so this
# drives it against a minimal host class providing only the surface the concern
# touches: the class hooks its `included do` invokes (before_action/after_action;
# protect_from_forgery is behind respond_to? and thus skipped), plus request /
# response / render / head / params.
#
# before_actions are NOT auto-run here (there is no filter runner), so each example
# invokes the relevant hook/action directly — which is exactly what lets us pin the
# per-request account loop and the hook seams in isolation.
RSpec.describe McpToolkit::Authority::ControllerMethods do
  let(:controller_class) do
    Class.new do
      def self.before_action(*); end
      def self.after_action(*); end
      include McpToolkit::Authority::ControllerMethods

      attr_accessor :request_body, :request_headers, :params
      attr_reader :rendered, :head_status

      def initialize
        @request_headers = {}
        @params = {}
        @response_headers = {}
      end

      def request
        @request ||= Struct.new(:headers, :body).new(request_headers, StringIO.new(request_body.to_s))
      end

      def response
        @response ||= Struct.new(:headers).new(@response_headers)
      end

      def render(payload)
        @rendered = payload
      end

      def head(status)
        @head_status = status
      end
    end
  end

  let(:controller) { controller_class.new }

  let(:account_one) { FakeAccount.new(1) }
  let(:account_two) { FakeAccount.new(2) }
  let(:principal) { FakePrincipal.new(id: 55, default_account: account_one, accounts: [account_one, account_two]) }

  # Bypass the before_action chain: set the authenticated principal directly for
  # examples that exercise dispatch/loop rather than authentication.
  def authenticate_as(a_principal)
    controller.instance_variable_set(:@mcp_principal, a_principal)
  end

  def body_for(*requests)
    JSON.generate(requests.size == 1 ? requests.first : requests)
  end

  def rpc(method, params = {}, id: 1)
    { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }
  end

  # ---- hook defaults + override seams --------------------------------------

  describe "hook defaults" do
    it "mcp_config defaults to McpToolkit.config" do
      expect(controller.send(:mcp_config)).to be(McpToolkit.config)
    end

    it "mcp_session_data defaults to an empty hash (a host binds e.g. { token_id: })" do
      expect(controller.send(:mcp_session_data)).to eq({})
    end

    it "mcp_session_data delegates to config.session_data_builder with the principal" do
      authenticate_as(principal)
      McpToolkit.config.session_data_builder = ->(principal:) { { token_id: principal.id } }

      expect(controller.send(:mcp_session_data)).to eq(token_id: 55)
    end

    it "mcp_session_data falls back to {} when the builder returns nil" do
      authenticate_as(principal)
      McpToolkit.config.session_data_builder = ->(**) {}

      expect(controller.send(:mcp_session_data)).to eq({})
    end

    it "mcp_rate_limit! delegates to config.rate_limiter with controller + principal" do
      authenticate_as(principal)
      seen = nil
      McpToolkit.config.rate_limiter = ->(controller:, principal:) { seen = { controller:, principal: } }

      controller.send(:mcp_rate_limit!)

      expect(seen).to eq(controller:, principal:)
    end

    it "mcp_rate_limit! is a no-op when no rate_limiter is configured" do
      expect { controller.send(:mcp_rate_limit!) }.not_to raise_error
    end

    it "mcp_track_usage delegates to config.usage_recorder with the call, account, principal, controller" do
      authenticate_as(principal)
      seen = nil
      McpToolkit.config.usage_recorder = lambda { |request_data:, account:, principal:, controller:|
        seen = { request_data:, account:, principal:, controller: }
      }

      request_data = rpc("tools/call")
      controller.send(:mcp_track_usage, request_data, account_one)

      expect(seen).to eq(request_data:, account: account_one, principal:, controller:)
    end

    it "mcp_flush_usage delegates to config.usage_flusher with the controller" do
      seen = nil
      McpToolkit.config.usage_flusher = ->(controller:) { seen = controller }

      controller.send(:mcp_flush_usage)

      expect(seen).to be(controller)
    end
  end

  # ---- built-in rate limiting (config.rate_limit_max_requests) -------------

  describe "#mcp_rate_limit! (built-in McpToolkit::RateLimiter)" do
    before do
      authenticate_as(principal)
      McpToolkit.config.rate_limit_max_requests = 2
      # reset_config! gives a fresh MemoryStore per example, so counts are isolated.
    end

    it "sets the X-RateLimit-* headers on an allowed request and renders nothing" do
      controller.send(:mcp_rate_limit!)

      headers = controller.response.headers
      expect(headers["X-RateLimit-Limit"]).to eq("2")
      expect(headers["X-RateLimit-Remaining"]).to eq("1")
      expect(headers["X-RateLimit-Reset"]).to be_present
      expect(controller.rendered).to be_nil
    end

    it "renders the JSON-RPC -32029 error at 429 with Retry-After once the limit is exceeded" do
      3.times { controller.send(:mcp_rate_limit!) } # keyed on principal.id, same window

      rendered = controller.rendered
      expect(rendered[:status]).to eq(:too_many_requests)
      expect(rendered[:json][:error][:code]).to eq(-32_029)
      expect(rendered[:json][:error][:message]).to include("Rate limit exceeded")
      expect(controller.response.headers["Retry-After"]).to be_present
      expect(controller.response.headers["X-RateLimit-Remaining"]).to eq("0")
    end

    it "keys the counter via the overridable mcp_rate_limit_key (default principal.id)" do
      expect(controller.send(:mcp_rate_limit_key)).to eq(principal.id)
    end

    it "reads the cap via the overridable mcp_rate_limit_max_requests hook" do
      expect(controller.send(:mcp_rate_limit_max_requests)).to eq(2)
    end

    it "is a no-op when no cap and no rate_limiter are configured" do
      McpToolkit.config.rate_limit_max_requests = nil

      controller.send(:mcp_rate_limit!)

      expect(controller.rendered).to be_nil
      expect(controller.response.headers["X-RateLimit-Limit"]).to be_nil
    end

    it "lets the config.rate_limiter escape hatch take precedence over the built-in" do
      seen = nil
      McpToolkit.config.rate_limiter = ->(controller:, principal:) { seen = { controller:, principal: } }

      controller.send(:mcp_rate_limit!)

      expect(seen).to eq(controller:, principal:)
      expect(controller.response.headers["X-RateLimit-Limit"]).to be_nil
    end
  end

  describe "#mcp_resolve_account (duck-typed on the principal)" do
    before { authenticate_as(principal) }

    it "returns the principal's default account when no candidate is supplied" do
      expect(controller.send(:mcp_resolve_account, rpc("tools/call"))).to eq(account_one)
    end

    it "resolves a candidate from params._meta" do
      request_data = rpc("tools/call", { "_meta" => { McpToolkit.config.account_meta_key => 2 } })

      expect(controller.send(:mcp_resolve_account, request_data)).to eq(account_two)
    end

    it "resolves a candidate from the tools/call account_id argument" do
      request_data = rpc("tools/call", { "arguments" => { "account_id" => 2 } })

      expect(controller.send(:mcp_resolve_account, request_data)).to eq(account_two)
    end

    it "resolves a candidate from the account-id header (request-wide fallback)" do
      controller.request_headers[McpToolkit.config.account_id_header] = "2"

      expect(controller.send(:mcp_resolve_account, rpc("tools/call"))).to eq(account_two)
    end

    it "raises InvalidParams for an account the token is not authorized for" do
      request_data = rpc("tools/call", { "arguments" => { "account_id" => 999 } })

      expect { controller.send(:mcp_resolve_account, request_data) }
        .to raise_error(McpToolkit::Protocol::InvalidParams, /not authorized/)
    end
  end

  # ---- authentication -------------------------------------------------------

  describe "#mcp_authenticate!" do
    it "renders a JSON-RPC 401 when no token is present" do
      controller.send(:mcp_authenticate!)

      expect(controller.rendered[:status]).to eq(:unauthorized)
      expect(controller.rendered[:json][:error][:message]).to include("Missing authorization token")
    end

    it "renders a JSON-RPC 401 when the token is invalid" do
      controller.request_headers["Authorization"] = "Bearer bad"
      McpToolkit.config.token_authenticator = ->(_plaintext) { nil }

      controller.send(:mcp_authenticate!)

      expect(controller.rendered[:status]).to eq(:unauthorized)
      expect(controller.rendered[:json][:error][:message]).to include("Invalid or expired token")
    end

    it "sets the principal (and touches last-used) for a valid token" do
      controller.request_headers["Authorization"] = "Bearer good"
      token = principal
      allow(token).to receive(:touch_last_used!)
      McpToolkit.config.token_authenticator = ->(_plaintext) { token }

      controller.send(:mcp_authenticate!)

      expect(controller.send(:mcp_principal)).to be(token)
      expect(token).to have_received(:touch_last_used!)
    end
  end

  # ---- session lifecycle ----------------------------------------------------

  describe "#mcp_resolve_session!" do
    before { authenticate_as(principal) }

    it "creates a session on initialize and echoes its id in the response header" do
      controller.request_body = body_for(rpc("initialize"))

      controller.send(:mcp_resolve_session!)

      session_id = controller.response.headers[described_class::SESSION_HEADER]
      expect(session_id).to be_present
      expect(McpToolkit::Session.find(session_id)).not_to be_nil
    end

    it "binds mcp_session_data to the created session (host override point)" do
      def controller.mcp_session_data = { token_id: mcp_principal.id }
      controller.request_body = body_for(rpc("initialize"))

      controller.send(:mcp_resolve_session!)

      session_id = controller.response.headers[described_class::SESSION_HEADER]
      expect(McpToolkit::Session.find(session_id).data).to eq(token_id: 55)
    end

    it "renders a 404 for a non-initialize POST with no valid session" do
      controller.request_body = body_for(rpc("ping"))

      controller.send(:mcp_resolve_session!)

      expect(controller.rendered[:status]).to eq(:not_found)
      expect(controller.rendered[:json][:error][:code]).to eq(-32_001)
    end
  end

  # ---- dispatch through #create --------------------------------------------

  describe "#create dispatch" do
    let(:whoami) { FakeTool.new { |ctx, _args| { account_id: ctx.account&.id, bearer: ctx.bearer_token } } }

    before do
      authenticate_as(principal)
      controller.request_headers["Authorization"] = "Bearer caller-token"
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "whoami" => whoami })
    end

    it "echoes the negotiated protocol version on initialize" do
      controller.request_body = body_for(rpc("initialize", { "protocolVersion" => "2025-03-26" }))

      controller.create

      expect(controller.rendered[:json][:result][:protocolVersion]).to eq("2025-03-26")
    end

    it "merges host tools with namespaced upstream tools on tools/list" do
      aggregator = instance_double(McpToolkit::Gateway::Aggregator)
      allow(McpToolkit::Gateway::Aggregator).to receive(:new).and_return(aggregator)
      allow(aggregator).to receive(:tool_definitions).and_return(
        [{ "name" => "billing__charge", "description" => "Charge", "inputSchema" => { "type" => "object" } }]
      )
      controller.request_body = body_for(rpc("tools/list"))

      controller.create

      names = controller.rendered[:json][:result][:tools].map { |t| t[:name] || t["name"] }
      expect(names).to include("whoami", "billing__charge")
    end

    it "routes a host tools/call through the dispatcher with the resolved account + bearer" do
      controller.request_body = body_for(rpc("tools/call", { "name" => "whoami", "arguments" => {} }))

      controller.create

      content = JSON.parse(controller.rendered[:json][:result][:content].first[:text])
      expect(content).to eq("account_id" => 1, "bearer" => "caller-token")
    end

    it "refuses a scoped tool the principal cannot reach (scope gate)" do
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "whoami" => FakeTool.new(scope: "billing__read") })
      controller.request_body = body_for(rpc("tools/call", { "name" => "whoami", "arguments" => {} }))

      controller.create

      expect(controller.rendered[:json][:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_REQUEST)
    end

    it "returns 202 Accepted with no body for a notification (no id)" do
      controller.request_body = body_for(rpc("notifications/initialized", {}, id: nil).except("id"))

      controller.create

      expect(controller.head_status).to eq(:accepted)
    end
  end

  # ---- the per-request account loop across a mixed-account BATCH ------------

  describe "per-request account loop (batch with mixed accounts)" do
    let(:whoami) { FakeTool.new { |ctx, _args| { account_id: ctx.account&.id } } }
    let(:recorded) { [] }

    before do
      authenticate_as(principal)
      events = recorded
      McpToolkit.config.tool_provider = FakeToolProvider.new(tools: { "whoami" => whoami })
      McpToolkit.config.usage_recorder = lambda { |request_data:, account:, principal:, **|
        events << { method: request_data["method"], account_id: account&.id, principal_id: principal.id }
      }

      controller.request_body = body_for(
        rpc("tools/call", { "name" => "whoami", "arguments" => {},
                            "_meta" => { McpToolkit.config.account_meta_key => 1 } }, id: 1),
        rpc("tools/call", { "name" => "whoami", "arguments" => {},
                            "_meta" => { McpToolkit.config.account_meta_key => 2 } }, id: 2)
      )
    end

    it "re-resolves the account per element and dispatches each with its own account" do
      controller.create

      results = controller.rendered[:json].map { |r| JSON.parse(r[:result][:content].first[:text])["account_id"] }
      expect(results).to eq([1, 2])
    end

    it "meters exactly one usage event per call, each against its own resolved account" do
      controller.create

      expect(recorded).to eq(
        [
          { method: "tools/call", account_id: 1, principal_id: 55 },
          { method: "tools/call", account_id: 2, principal_id: 55 }
        ]
      )
    end

    it "isolates a per-element account failure to that element's JSON-RPC error" do
      controller.request_body = body_for(
        rpc("tools/call", { "name" => "whoami", "arguments" => {},
                            "_meta" => { McpToolkit.config.account_meta_key => 1 } }, id: 1),
        rpc("tools/call", { "name" => "whoami", "arguments" => { "account_id" => 999 } }, id: 2)
      )

      controller.create

      responses = controller.rendered[:json]
      ok = responses.find { |r| r[:id] == 1 || r["id"] == 1 }
      failed = responses.find { |r| r[:id] == 2 || r["id"] == 2 }
      expect(JSON.parse(ok[:result][:content].first[:text])["account_id"]).to eq(1)
      expect(failed[:error][:code]).to eq(McpToolkit::Protocol::ErrorCodes::INVALID_PARAMS)
    end
  end
end
