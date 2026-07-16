# frozen_string_literal: true

require "spec_helper"

# The OAuth bridge concern runs WITHOUT Rails in the gem's suite, so this drives it
# against a minimal host class providing only the surface it touches: params,
# request origin, render and redirect_to. before_actions are not auto-run (there is
# no filter runner), which is fine — the bridge has none; each action guards itself.
RSpec.describe McpToolkit::Oauth::ControllerMethods do
  let(:controller_class) do
    Class.new do
      include McpToolkit::Oauth::ControllerMethods

      attr_accessor :params
      attr_reader :rendered, :redirected_to

      def initialize
        @params = {}
      end

      def request
        @request ||= Struct.new(:base_url).new("https://mcp.example.test")
      end

      def render(*args, **options)
        @rendered = { template: args.first, options: }
      end

      def redirect_to(url, **options)
        @redirected_to = { url:, options: }
      end
    end
  end

  let(:controller) { controller_class.new }
  let(:redirect_uri) { "https://client.example/callback" }
  let(:principal) { FakePrincipal.new(id: 7) }
  let(:valid_token) { "tok_live" }

  # A verifier and its real S256 challenge, so the PKCE check is exercised against
  # genuine values rather than a stubbed comparison.
  let(:code_verifier) { "a-high-entropy-code-verifier-string" }
  let(:code_challenge) do
    [Digest::SHA256.digest(code_verifier)].pack("m0").tr("+/", "-_").delete("=")
  end

  before do
    McpToolkit.configure do |c|
      c.auth_role = :authority
      c.server_name = "example-mcp"
      c.oauth_allowed_redirect_uris = [redirect_uri]
      c.token_authenticator = ->(plaintext) { plaintext == valid_token ? principal : nil }
    end
  end

  def authorize_params(overrides = {})
    {
      response_type: "code",
      redirect_uri:,
      state: "opaque-state",
      code_challenge:,
      code_challenge_method: "S256"
    }.merge(overrides)
  end

  # Runs the authorize + approve legs and returns the issued code.
  def issue_code(overrides = {})
    controller.params = authorize_params(overrides).merge(access_token: valid_token)
    controller.approve
    URI.decode_www_form(URI.parse(controller.redirected_to[:url]).query).to_h["code"]
  end

  describe "#protected_resource" do
    it "identifies the MCP endpoint from the live origin and points at this app as the authorization server" do
      controller.protected_resource

      expect(controller.rendered[:options][:json]).to eq(
        resource: "https://mcp.example.test/mcp",
        authorization_servers: ["https://mcp.example.test"],
        bearer_methods_supported: ["header"]
      )
    end

    it "tracks a host that mounted the engine somewhere other than /mcp" do
      McpToolkit.config.oauth_resource_path = "/agent/mcp"
      controller.protected_resource

      expect(controller.rendered[:options][:json][:resource]).to eq("https://mcp.example.test/agent/mcp")
    end
  end

  describe "#authorization_server" do
    subject(:metadata) do
      controller.authorization_server
      controller.rendered[:options][:json]
    end

    it "advertises the origin as issuer so an RFC 8414 lookup lands on the drawn root path" do
      expect(metadata[:issuer]).to eq("https://mcp.example.test")
    end

    it "advertises S256, which clients send a challenge for regardless" do
      expect(metadata[:code_challenge_methods_supported]).to eq(["S256"])
    end

    it "advertises public clients (no token-endpoint authentication)" do
      expect(metadata[:token_endpoint_auth_methods_supported]).to eq(["none"])
    end

    it "advertises only the authorization_code grant (no refresh — the pasted token's own expiry is the lifetime)" do
      expect(metadata[:grant_types_supported]).to eq(["authorization_code"])
    end

    it "points at the bridge's endpoints under the engine mount" do
      expect(metadata).to include(
        authorization_endpoint: "https://mcp.example.test/mcp/oauth/authorize",
        token_endpoint: "https://mcp.example.test/mcp/oauth/token",
        registration_endpoint: "https://mcp.example.test/mcp/oauth/register"
      )
    end
  end

  describe "#register" do
    it "hands back a client identifier" do
      controller.register

      expect(controller.rendered[:options][:json][:client_id]).to be_a(String).and be_present
    end

    it "issues a fresh identifier per call and stores neither (nothing downstream reads one)" do
      controller.register
      first = controller.rendered[:options][:json][:client_id]
      controller.register

      expect(controller.rendered[:options][:json][:client_id]).not_to eq(first)
    end
  end

  describe "#authorize" do
    it "renders the paste page for a well-formed request" do
      controller.params = authorize_params
      controller.authorize

      expect(controller.rendered).to include(template: :authorize)
      expect(controller.rendered[:options]).to include(layout: false)
    end

    it "refuses an unregistered redirect_uri rather than redirecting to it" do
      controller.params = authorize_params(redirect_uri: "https://attacker.example/steal")
      controller.authorize

      expect(controller.rendered[:options]).to include(status: :bad_request)
      expect(controller.redirected_to).to be_nil
    end

    it "refuses a request with no PKCE challenge" do
      controller.params = authorize_params(code_challenge: nil)
      controller.authorize

      expect(controller.rendered[:options]).to include(status: :bad_request)
    end

    it "refuses a downgraded (plain) PKCE method" do
      controller.params = authorize_params(code_challenge_method: "plain")
      controller.authorize

      expect(controller.rendered[:options]).to include(status: :bad_request)
    end
  end

  describe "#approve" do
    it "redirects to the client with a code and the echoed state" do
      controller.params = authorize_params.merge(access_token: valid_token)
      controller.approve

      redirect = URI.parse(controller.redirected_to[:url])
      query = URI.decode_www_form(redirect.query).to_h

      expect("#{redirect.scheme}://#{redirect.host}#{redirect.path}").to eq(redirect_uri)
      expect(query["code"]).to be_present
      expect(query["state"]).to eq("opaque-state")
    end

    it "preserves a query the client's redirect_uri already carried" do
      with_query = "#{redirect_uri}?tenant=acme"
      McpToolkit.config.oauth_allowed_redirect_uris = [with_query]
      controller.params = authorize_params(redirect_uri: with_query).merge(access_token: valid_token)
      controller.approve

      query = URI.decode_www_form(URI.parse(controller.redirected_to[:url]).query).to_h
      expect(query["tenant"]).to eq("acme")
      expect(query["code"]).to be_present
    end

    it "re-renders the page with an error for an unknown token, without issuing a code" do
      controller.params = authorize_params.merge(access_token: "not-a-real-token")
      controller.approve

      expect(controller.redirected_to).to be_nil
      expect(controller.rendered).to include(template: :authorize)
      expect(controller.instance_variable_get(:@mcp_oauth_error)).to be_present
    end

    it "re-renders the page when no token was pasted" do
      controller.params = authorize_params.merge(access_token: "")
      controller.approve

      expect(controller.redirected_to).to be_nil
      expect(controller.rendered[:options]).to include(status: :unprocessable_content)
    end

    # The hidden fields are attacker-tamperable, so the allowlist is re-checked on
    # this leg too — the check on #authorize alone would not bind the POST.
    it "refuses a redirect_uri swapped between the two legs" do
      controller.params = authorize_params(redirect_uri: "https://attacker.example/steal")
                          .merge(access_token: valid_token)
      controller.approve

      expect(controller.redirected_to).to be_nil
      expect(controller.rendered[:options]).to include(status: :bad_request)
    end
  end

  describe "#token" do
    let(:exchange_params) do
      { grant_type: "authorization_code", redirect_uri:, code_verifier: }
    end

    it "hands back the pasted token itself" do
      code = issue_code
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(access_token: valid_token, token_type: "Bearer")
    end

    it "rejects a grant type other than authorization_code" do
      controller.params = exchange_params.merge(code: issue_code, grant_type: "client_credentials")
      controller.token

      expect(controller.rendered[:options]).to include(json: { error: "unsupported_grant_type" }, status: :bad_request)
    end

    it "rejects an unknown code" do
      controller.params = exchange_params.merge(code: "never-issued")
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    it "burns the code on first use" do
      code = issue_code
      controller.params = exchange_params.merge(code:)
      controller.token
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    it "rejects a code redeemed with the wrong PKCE verifier" do
      controller.params = exchange_params.merge(code: issue_code, code_verifier: "wrong-verifier")
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    it "rejects a code redeemed with no PKCE verifier at all" do
      controller.params = exchange_params.merge(code: issue_code, code_verifier: nil)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    it "rejects a code redeemed against a different redirect_uri than it was issued for" do
      code = issue_code
      McpToolkit.config.oauth_allowed_redirect_uris = [redirect_uri, "https://client.example/other"]
      controller.params = exchange_params.merge(code:, redirect_uri: "https://client.example/other")
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    # The bridge is an envelope, not a second source of truth: a token revoked
    # between the paste and the exchange must not come back out of it.
    it "rejects a token revoked between authorization and exchange" do
      code = issue_code
      McpToolkit.config.token_authenticator = ->(_plaintext) { nil }
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end

    it "lets an expired code lapse" do
      code = issue_code
      McpToolkit.config.cache_store.delete("#{described_class::CODE_CACHE_PREFIX}#{code}")
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end
  end
end
