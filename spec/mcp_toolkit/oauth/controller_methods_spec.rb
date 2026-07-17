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

      def response
        @response ||= Struct.new(:headers).new({})
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

  # What a client posts to the token endpoint, minus the code it just received.
  let(:exchange_params) do
    { grant_type: "authorization_code", redirect_uri:, code_verifier: }
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
    it "identifies the MCP endpoint from the live origin and points at it as the authorization server" do
      controller.protected_resource

      expect(controller.rendered[:options][:json]).to eq(
        resource: "https://mcp.example.test/mcp",
        authorization_servers: ["https://mcp.example.test/mcp"],
        bearer_methods_supported: ["header"]
      )
    end

    it "tracks a host that mounted the engine somewhere other than /mcp" do
      McpToolkit.config.oauth_resource_path = "/agent/mcp"
      controller.protected_resource

      expect(controller.rendered[:options][:json][:resource]).to eq("https://mcp.example.test/agent/mcp")
    end
  end

  # The bare well-known paths are ORIGIN-GLOBAL: they describe the authorization
  # server of the whole host, which on an origin already running an unrelated
  # OAuth provider is that provider's to claim. Path-scoping (RFC 8414 §3.1 /
  # RFC 9728 §3.1) is what lets both live on one host.
  describe "metadata locations" do
    it "scopes both documents under the engine's mount, claiming nothing at the origin root" do
      expect(McpToolkit.config.oauth_protected_resource_path).to eq("/.well-known/oauth-protected-resource/mcp")
      expect(McpToolkit.config.oauth_authorization_server_path).to eq("/.well-known/oauth-authorization-server/mcp")
    end

    it "issues a path-ful issuer, so a client path-INSERTS and never probes the origin root" do
      controller.authorization_server
      issuer = controller.rendered[:options][:json][:issuer]

      expect(issuer).to eq("https://mcp.example.test/mcp")
      # The document's issuer must equal the identifier used to construct its URL.
      expect(URI.parse(issuer).path).to eq(McpToolkit.config.oauth_resource_path_component)
    end

    it "falls back to the bare paths only for an endpoint mounted AT the origin root" do
      McpToolkit.config.oauth_resource_path = "/"

      expect(McpToolkit.config.oauth_protected_resource_path).to eq("/.well-known/oauth-protected-resource")
      expect(McpToolkit.config.oauth_authorization_server_path).to eq("/.well-known/oauth-authorization-server")
    end

    it "drops a trailing slash rather than emitting a doubled one" do
      McpToolkit.config.oauth_resource_path = "/mcp/"

      expect(McpToolkit.config.oauth_protected_resource_path).to eq("/.well-known/oauth-protected-resource/mcp")
      expect(McpToolkit.config.oauth_resource_path_component).to eq("/mcp")
    end
  end

  describe "#authorization_server" do
    subject(:metadata) do
      controller.authorization_server
      controller.rendered[:options][:json]
    end

    it "advertises the path-ful MCP endpoint as issuer, so an RFC 8414 lookup path-inserts" do
      expect(metadata[:issuer]).to eq("https://mcp.example.test/mcp")
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

    # An exact-match allowlist makes "the client's callback has a trailing slash"
    # indistinguishable from an attack, so the offered value has to be recoverable
    # from the logs or an operator is left guessing it.
    it "logs the offered redirect_uri and the allowlist, so a misconfiguration names itself" do
      logger = instance_double(Logger, warn: nil)
      McpToolkit.config.logger = logger
      controller.params = authorize_params(redirect_uri: "https://client.example/callback/")
      controller.authorize

      expect(logger).to have_received(:warn).with(
        a_string_including("https://client.example/callback/").and(a_string_including(redirect_uri))
      )
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

  # Loopback (RFC 8252 §7.3) is the ONE target accepted without being named,
  # because it is the one that cannot be named: the client picks an ephemeral port
  # at runtime. Everything else — including a private-use scheme, which also keeps
  # the code on the device — is a fixed string and goes in the allowlist.
  describe "loopback redirect targets" do
    def authorize_with(uri)
      controller.params = authorize_params(redirect_uri: uri)
      controller.authorize
      controller.rendered
    end

    context "when the host has not opted in" do
      it "refuses loopback like any other unnamed target" do
        expect(authorize_with("http://127.0.0.1:54321/cb")[:options]).to include(status: :bad_request)
      end
    end

    context "when the host allows loopback" do
      before { McpToolkit.config.oauth_allow_loopback_redirects = true }

      # The port is ephemeral, so it cannot be registered ahead of time — which is
      # the entire reason RFC 8252 §7.3 exists.
      it "accepts loopback on an arbitrary port" do
        expect(authorize_with("http://127.0.0.1:54321/cb")[:template]).to eq(:authorize)
      end

      it "accepts the loopback name and the IPv6 literal clients really send" do
        expect(authorize_with("http://localhost:3000/cb")[:template]).to eq(:authorize)
        expect(authorize_with("http://[::1]:8080/cb")[:template]).to eq(:authorize)
      end

      # The switch says "loopback", never "any scheme that looks local". A
      # REGISTERED NETWORK scheme names a remote host and would carry the code
      # straight off the device, so no scheme is judged local by its absence from
      # a list of ones we thought of — a private-use scheme is a fixed string and
      # belongs in the allowlist like anything else.
      it "refuses registered network schemes, which name a remote host" do
        ["ssh://attacker.example/cb", "gopher://attacker.example/cb", "ldap://attacker.example/cb",
         "telnet://attacker.example/cb", "smb://attacker.example/cb", "nfs://attacker.example/cb"]
          .each { |uri| expect(authorize_with(uri)[:options]).to include(status: :bad_request) }
      end

      it "refuses an unnamed private-use scheme (it is a fixed string — allowlist it)" do
        expect(authorize_with("cursor://anysphere.cursor-retrieval/oauth/callback")[:options])
          .to include(status: :bad_request)
        expect(authorize_with("com.example.app:/oauth2redirect")[:options]).to include(status: :bad_request)
      end

      it "still refuses a remote https callback that was never named" do
        expect(authorize_with("https://attacker.example/steal")[:options]).to include(status: :bad_request)
      end

      # Everything below is remote wearing a loopback costume. Each is checked
      # against the PARSED host, which is what a browser actually resolves.
      it "refuses a host that merely embeds a loopback address" do
        # userinfo: the host is evil.example
        expect(authorize_with("http://127.0.0.1@evil.example/cb")[:options]).to include(status: :bad_request)
        # a subdomain of the attacker's domain
        expect(authorize_with("http://127.0.0.1.evil.example/cb")[:options]).to include(status: :bad_request)
        # loopback hidden in a fragment
        expect(authorize_with("http://evil.example/cb#@127.0.0.1/")[:options]).to include(status: :bad_request)
      end

      it "refuses a scheme-relative uri, which names no scheme to judge" do
        expect(authorize_with("//evil.example/cb")[:options]).to include(status: :bad_request)
      end

      it "refuses pseudo-schemes a browser may treat as script or local content" do
        ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "blob:https://evil.example/x"]
          .each { |uri| expect(authorize_with(uri)[:options]).to include(status: :bad_request) }
      end

      it "refuses a redirect_uri carrying a fragment, which OAuth forbids" do
        expect(authorize_with("http://127.0.0.1:5/cb#frag")[:options]).to include(status: :bad_request)
      end

      it "hands a code to a loopback client through the full flow" do
        loopback_uri = "http://127.0.0.1:54321/cb"
        controller.params = authorize_params(redirect_uri: loopback_uri).merge(access_token: valid_token)
        controller.approve

        expect(controller.redirected_to[:url]).to start_with("#{loopback_uri}?code=")
      end

      # An allowlisted private-use scheme must still WORK — the rule is "name it",
      # not "no desktop clients".
      it "hands a code to an allowlisted private-use scheme client" do
        scheme_uri = "cursor://anysphere.cursor-retrieval/oauth/callback"
        McpToolkit.config.oauth_allowed_redirect_uris = [scheme_uri]
        controller.params = authorize_params(redirect_uri: scheme_uri).merge(access_token: valid_token)
        controller.approve

        expect(controller.redirected_to[:url]).to start_with("#{scheme_uri}?code=")
      end
    end
  end

  # RFC 6749 §5.1 makes both headers a MUST on any response carrying a token, and
  # RFC 9700 §4.12 wants a 303 after a POST that carried a credential.
  describe "the token-bearing responses" do
    it "forbids caching the token response" do
      code = issue_code
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.response.headers["Cache-Control"]).to eq("no-store")
      expect(controller.response.headers["Pragma"]).to eq("no-cache")
    end

    # The approve POST carried the operator's token in its body; only 303 tells the
    # browser unambiguously to GET the callback without resending it.
    it "redirects with 303 after the credential POST, not 302" do
      controller.params = authorize_params.merge(access_token: valid_token)
      controller.approve

      expect(controller.redirected_to[:options]).to include(status: :see_other)
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

    # Expiry is simulated by emptying the store rather than deleting a
    # hand-built key: the key derivation is the bridge's own business, and a spec
    # that restates it passes just as happily when it is wrong.
    it "lets an expired code lapse" do
      code = issue_code
      McpToolkit.config.cache_store.clear
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end
  end

  # `cache_store` is documented to be the host's shared Rails.cache, and what is
  # parked in it is the operator's own long-lived token — so what a dump of that
  # store would yield is a property worth pinning, not an implementation detail.
  describe "what the code leaves in the cache" do
    # Reaches into the store deliberately: the claim is about the bytes a snapshot
    # of it would contain, so it has to be asserted against the stored entries
    # themselves — `Entry#value` and not `Entry#to_s`, which shows an object id and
    # would let this pass while the token sat there in the clear.
    def cached_keys
      McpToolkit.config.cache_store.instance_variable_get(:@data).keys
    end

    def cached_values
      McpToolkit.config.cache_store.instance_variable_get(:@data).values.map { |entry| entry.value.to_s }
    end

    # Guards the guard: if the payload were NOT sealed, this is the assertion that
    # has to fail, so prove the plaintext would be visible to it.
    it "would see a plaintext token in the store (so the assertion below means something)" do
      McpToolkit.config.cache_store.write("probe", { access_token: valid_token }.to_json, expires_in: 60)

      expect(cached_values.join).to include(valid_token)
    end

    it "parks neither the token nor the code itself" do
      code = issue_code

      expect(cached_keys.join).not_to include(code)
      expect(cached_values.join).not_to include(valid_token)
    end

    it "still round-trips the token to the client holding the code" do
      code = issue_code
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(access_token: valid_token, token_type: "Bearer")
    end

    # Sealed as well as hidden: a payload swapped in the store does not decrypt,
    # so a writable cache cannot be used to inject a token of the attacker's
    # choosing into the exchange.
    it "refuses a payload that was tampered with in the store" do
      code = issue_code
      McpToolkit.config.cache_store.write(cached_keys.first, "tampered-ciphertext", expires_in: 60)
      controller.params = exchange_params.merge(code:)
      controller.token

      expect(controller.rendered[:options][:json]).to eq(error: "invalid_grant")
    end
  end

  # A metadata document names the authorization_endpoint an operator will be sent
  # to, and it is built from the caller-influenced request origin — so it is
  # precisely the thing a shared cache must not hold on another client's behalf.
  describe "metadata caching" do
    it "forbids storing either document" do
      controller.protected_resource
      expect(controller.response.headers["Cache-Control"]).to eq("no-store")

      controller.authorization_server
      expect(controller.response.headers["Cache-Control"]).to eq("no-store")
    end
  end
end
