# frozen_string_literal: true

require "spec_helper"

# End-to-end spec for the OAuth authorization bridge, against a REAL Rails app.
#
# The sibling controller_methods_spec.rb drives the concern against a fake
# controller, which is fast and pins the logic — but a fake controller cannot
# prove the parts that only Rails does: that the routes are drawn where a client
# looks for them, that the authorization page actually RENDERS (the view is
# resolved from the engine's app/views through a dynamically built controller),
# that `redirect_to ..., allow_other_host: true` is permitted, and that the token
# handed back at the end genuinely authenticates a subsequent MCP call. A fake
# would only confirm the fake.
#
# Following engine_route_reload_spec.rb: booting a real Rails::Application
# in-process would irreversibly mutate global state (Rails.application, the
# Zeitwerk loader set eager_load_spec inspects, the engine's lazy route set) and
# contaminate this otherwise Rails-absent suite under random ordering. So the boot
# runs in an ISOLATED CHILD process that walks the whole flow exactly as a client
# would and prints the result as JSON for this process to assert on.
#
# Rails-only: railties/actionpack are a TEST dependency, so the group is skipped
# when Rails is unavailable.
rails_available =
  begin
    require "rails/version"
    true
  rescue LoadError
    false
  end

RSpec.describe "OAuth bridge end to end", if: rails_available do
  # The driver: boots a minimal app configured as an authority with the bridge on,
  # then performs the client's exact sequence — discover, register, authorize,
  # paste, exchange, and finally call the MCP endpoint with what came back.
  #
  # Named distinctly (not `DRIVER`): a constant assigned inside an RSpec block
  # lands on Object, so a bare name would collide with the sibling
  # engine_route_reload_spec's driver and silently hand one spec the other's boot.
  OAUTH_BRIDGE_DRIVER = <<~'RUBY'
    require "bundler/setup"
    require "json"
    require "tmpdir"
    require "logger"
    require "mcp_toolkit"
    require "rails"
    require "action_controller/railtie"
    require "rack/test"

    REDIRECT_URI = "https://client.example/callback"
    VALID_TOKEN  = "tok_pasted_by_the_operator"

    # A duck-typed principal: what the authority path reads off a token.
    Principal = Struct.new(:id) do
      def authorized_for_scope?(_scope) = true
      def default_account = Struct.new(:id).new(99)
      def authorize_account(_candidate) = default_account
      def superuser? = false
    end

    McpToolkit.configure do |c|
      # Mirror a real authority: the MCP transport is a JSON-only endpoint, so its
      # parent is ActionController::API — which CANNOT render an HTML view. The
      # bridge's page is one, and it must render anyway (it has its own parent).
      c.parent_controller = "ActionController::API"
      c.auth_role = :authority
      c.server_name = "example-mcp"
      c.oauth_allowed_redirect_uris = [REDIRECT_URI]
      c.token_authenticator = ->(plaintext) { plaintext == VALID_TOKEN ? Principal.new(1) : nil }
    end

    unless McpToolkit.const_defined?(:Engine, false)
      load File.expand_path("lib/mcp_toolkit/engine.rb", Dir.pwd)
    end

    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.consider_all_requests_local = true
      config.secret_key_base = "oauth-bridge-spec-secret-key-base"
      config.logger = Logger.new(IO::NULL)
      config.root = Dir.mktmpdir("mcp_toolkit_oauth_spec")
      config.hosts.clear # Rack::Test requests arrive as example.org
    end

    # A host that ALREADY runs its own OAuth provider at the conventional
    # top-level /oauth/* paths (the shape Doorkeeper draws). The bridge must not
    # touch any of it.
    class HostOauthController < ActionController::Base
      def authorize = render(plain: "HOST_AUTHORIZE")
      def token = render(plain: "HOST_TOKEN")
      def token_info = render(plain: "HOST_TOKEN_INFO")
    end

    app.initialize!
    app.routes.draw do
      # Drawn BEFORE the bridge, as in a host whose use_doorkeeper call sits at the
      # top of its route set — first match wins, so this is the order that would
      # expose a collision.
      get  "/oauth/authorize",  to: "host_oauth#authorize"
      post "/oauth/token",      to: "host_oauth#token"
      get  "/oauth/token/info", to: "host_oauth#token_info"

      McpToolkit.draw_oauth_metadata_routes(self)
      mount McpToolkit::Engine => "/mcp"
    end

    session = Rack::Test::Session.new(Rack::MockSession.new(app))
    result  = {}

    # 0. The host's existing OAuth provider must answer exactly as before.
    session.get("/oauth/authorize")
    result["host_authorize"] = session.last_response.body
    session.post("/oauth/token")
    result["host_token"] = session.last_response.body
    session.get("/oauth/token/info")
    result["host_token_info"] = session.last_response.body

    # 0b. Every path the bridge claims OUTSIDE its own engine mount. Anything here
    # beyond the two metadata documents would be a land-grab on the host's routes.
    result["host_level_paths"] = app.routes.routes.filter_map { |r|
      path = r.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      next unless r.defaults[:controller].to_s.start_with?("mcp_toolkit/")
      path
    }
    # And the engine's own set, which must stay under the mount.
    result["engine_paths"] = McpToolkit::Engine.routes.routes.map { |r|
      r.path.spec.to_s.sub(/\(\.:format\)\z/, "")
    }
    result["oauth_controller_parent"] = McpToolkit::OauthController.superclass.name
    result["server_controller_parent"] = McpToolkit::ServerController.superclass.name

    # 1. An unauthenticated MCP call must point the client at the metadata.
    session.post("/mcp", JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
                 "CONTENT_TYPE" => "application/json")
    result["unauthenticated_status"] = session.last_response.status
    result["www_authenticate"] = session.last_response.headers["WWW-Authenticate"]

    # 2 + 3. Discovery, at the PATH-SCOPED locations (RFC 9728 §3.1 / RFC 8414 §3.1).
    session.get("/.well-known/oauth-protected-resource/mcp")
    result["prm_status"] = session.last_response.status
    result["prm"] = JSON.parse(session.last_response.body)

    session.get("/.well-known/oauth-authorization-server/mcp")
    result["as_status"] = session.last_response.status
    result["as"] = JSON.parse(session.last_response.body)

    # The bare, ORIGIN-GLOBAL well-known paths must stay untouched — they describe
    # the whole origin's authorization server, which on a host already running one
    # is that provider's to claim. Nothing here may answer them.
    session.get("/.well-known/oauth-protected-resource")
    result["bare_prm_status"] = session.last_response.status
    session.get("/.well-known/oauth-authorization-server")
    result["bare_as_status"] = session.last_response.status

    # 4. Client registration.
    session.post("/mcp/oauth/register", JSON.generate({ redirect_uris: [REDIRECT_URI] }),
                 "CONTENT_TYPE" => "application/json")
    result["register_status"] = session.last_response.status
    result["register"] = JSON.parse(session.last_response.body)

    # 5. The authorization page — does the view actually render?
    verifier  = "e2e-high-entropy-code-verifier-value"
    challenge = [Digest::SHA256.digest(verifier)].pack("m0").tr("+/", "-_").delete("=")
    authorize_query = {
      response_type: "code", client_id: result["register"]["client_id"], redirect_uri: REDIRECT_URI,
      state: "opaque-state", code_challenge: challenge, code_challenge_method: "S256"
    }
    session.get("/mcp/oauth/authorize", authorize_query)
    result["authorize_status"] = session.last_response.status
    authorize_body = session.last_response.body
    result["authorize_renders_form"] = authorize_body.include?("access_token") && authorize_body.include?("<form")
    result["authorize_echoes_challenge"] = authorize_body.include?(challenge)
    result["authorize_masks_input"] = authorize_body.include?('type="password"')

    # 5b. A page served for an unregistered redirect_uri would be the open redirect.
    session.get("/mcp/oauth/authorize", authorize_query.merge(redirect_uri: "https://attacker.example/x"))
    result["authorize_unregistered_status"] = session.last_response.status

    # 6. Paste the token; expect a redirect back to the client carrying a code.
    session.post("/mcp/oauth/authorize", authorize_query.merge(access_token: VALID_TOKEN))
    result["approve_status"] = session.last_response.status
    location = session.last_response.headers["Location"]
    result["approve_location_host"] = location && location.split("?").first
    code = location && Rack::Utils.parse_query(URI.parse(location).query)["code"]
    result["approve_state"] = location && Rack::Utils.parse_query(URI.parse(location).query)["state"]

    # 6b. A bad paste must not issue a code.
    session.post("/mcp/oauth/authorize", authorize_query.merge(access_token: "wrong-token"))
    result["approve_bad_token_status"] = session.last_response.status
    result["approve_bad_token_redirected"] = !session.last_response.headers["Location"].nil?

    # 7. Exchange the code (form-encoded, as the spec requires of a token endpoint).
    session.post("/mcp/oauth/token", {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT_URI, code_verifier: verifier
    })
    result["token_status"] = session.last_response.status
    result["token_content_type"] = session.last_response.headers["Content-Type"]
    token_body = JSON.parse(session.last_response.body)
    result["token_body"] = token_body
    result["token_is_the_pasted_token"] = token_body["access_token"] == VALID_TOKEN

    # 8. THE POINT: does what came out actually authenticate an MCP call?
    session.post("/mcp", JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
                 "CONTENT_TYPE" => "application/json",
                 "HTTP_AUTHORIZATION" => "Bearer #{token_body["access_token"]}")
    result["mcp_with_issued_token_status"] = session.last_response.status
    result["mcp_with_issued_token_body"] = JSON.parse(session.last_response.body)

    # 9. And the code must be spent.
    session.post("/mcp/oauth/token", {
      grant_type: "authorization_code", code: code, redirect_uri: REDIRECT_URI, code_verifier: verifier
    })
    result["replayed_code_status"] = session.last_response.status
    result["replayed_code_body"] = JSON.parse(session.last_response.body)

    puts JSON.generate(result)
  RUBY

  before(:all) do
    require "json"
    require "open3"

    # This spec sits a level deeper than its sibling under spec/mcp_toolkit/oauth.
    gem_root = File.expand_path("../../..", __dir__)
    stdout, stderr, status = Open3.capture3(Gem.ruby, "-e", OAUTH_BRIDGE_DRIVER, chdir: gem_root)
    raise "oauth bridge driver failed (#{status.exitstatus}):\n#{stderr}" unless status.success?

    @result = JSON.parse(stdout.lines.last)
  end

  # The bridge is additive to a host that already runs an OAuth provider (as an
  # app with Doorkeeper for its own API does). It must not shadow one route of it.
  describe "coexistence with a host's existing OAuth provider" do
    it "leaves the host's /oauth/authorize, /oauth/token and /oauth/token/info untouched" do
      expect(@result.fetch("host_authorize")).to eq("HOST_AUTHORIZE")
      expect(@result.fetch("host_token")).to eq("HOST_TOKEN")
      expect(@result.fetch("host_token_info")).to eq("HOST_TOKEN_INFO")
    end

    it "claims nothing at host level beyond the two path-scoped metadata documents" do
      expect(@result.fetch("host_level_paths")).to contain_exactly(
        "/.well-known/oauth-protected-resource/mcp",
        "/.well-known/oauth-authorization-server/mcp"
      )
    end

    it "keeps every one of its own endpoints under the engine mount" do
      expect(@result.fetch("engine_paths")).to contain_exactly(
        "/", "/", "/", "/health", "/tokens/introspect",
        "/oauth/authorize", "/oauth/authorize", "/oauth/token", "/oauth/register"
      )
    end
  end

  # The transport is JSON-only and its parent is ActionController::API, which
  # cannot render HTML. Enabling the bridge must not force a host to change that.
  describe "controller parents" do
    it "leaves the transport on the host's ActionController::API parent" do
      expect(@result.fetch("server_controller_parent")).to eq("ActionController::API")
    end

    it "builds the bridge from its own parent, so it can render a page" do
      expect(@result.fetch("oauth_controller_parent")).to eq("ActionController::Base")
    end
  end

  describe "the 401 that starts the flow" do
    it "challenges an unauthenticated caller with a resource_metadata pointer" do
      expect(@result.fetch("unauthenticated_status")).to eq(401)
      expect(@result.fetch("www_authenticate")).to eq(
        %(Bearer resource_metadata="http://example.org/.well-known/oauth-protected-resource/mcp")
      )
    end
  end

  describe "discovery" do
    it "answers protected-resource metadata path-scoped under the mount" do
      expect(@result.fetch("prm_status")).to eq(200)
      expect(@result.fetch("prm")).to include(
        "resource" => "http://example.org/mcp",
        "authorization_servers" => ["http://example.org/mcp"]
      )
    end

    it "answers authorization-server metadata at the path-INSERTED location" do
      expect(@result.fetch("as_status")).to eq(200)
      expect(@result.fetch("as")).to include(
        "issuer" => "http://example.org/mcp",
        "authorization_endpoint" => "http://example.org/mcp/oauth/authorize",
        "token_endpoint" => "http://example.org/mcp/oauth/token",
        "code_challenge_methods_supported" => ["S256"]
      )
    end

    # The load-bearing one for a host that already runs its own OAuth: the bare
    # well-known paths are origin-global and must remain that provider's to claim.
    it "leaves BOTH origin-global well-known paths unclaimed" do
      expect(@result.fetch("bare_prm_status")).to eq(404)
      expect(@result.fetch("bare_as_status")).to eq(404)
    end
  end

  describe "registration" do
    it "accepts a JSON registration and returns a client_id" do
      expect(@result.fetch("register_status")).to eq(201)
      expect(@result.fetch("register")["client_id"]).to be_a(String).and be_present
    end
  end

  describe "the authorization page" do
    it "renders the paste form" do
      expect(@result.fetch("authorize_status")).to eq(200)
      expect(@result.fetch("authorize_renders_form")).to be(true)
    end

    it "carries the PKCE challenge through to the second leg" do
      expect(@result.fetch("authorize_echoes_challenge")).to be(true)
    end

    it "masks the pasted token" do
      expect(@result.fetch("authorize_masks_input")).to be(true)
    end

    it "refuses to render for an unregistered redirect_uri" do
      expect(@result.fetch("authorize_unregistered_status")).to eq(400)
    end
  end

  describe "the paste" do
    it "redirects back to the client with the echoed state" do
      expect(@result.fetch("approve_status")).to eq(302)
      expect(@result.fetch("approve_location_host")).to eq("https://client.example/callback")
      expect(@result.fetch("approve_state")).to eq("opaque-state")
    end

    it "does not redirect (or issue a code) for a token that does not authenticate" do
      expect(@result.fetch("approve_bad_token_status")).to eq(422)
      expect(@result.fetch("approve_bad_token_redirected")).to be(false)
    end
  end

  describe "the exchange" do
    it "accepts a form-encoded request and returns JSON" do
      expect(@result.fetch("token_status")).to eq(200)
      expect(@result.fetch("token_content_type")).to include("application/json")
    end

    it "hands back the operator's own token, as a bearer" do
      expect(@result.fetch("token_is_the_pasted_token")).to be(true)
      expect(@result.fetch("token_body")).to include("token_type" => "Bearer")
    end

    it "spends the code (a replay is refused)" do
      expect(@result.fetch("replayed_code_status")).to eq(400)
      expect(@result.fetch("replayed_code_body")).to eq("error" => "invalid_grant")
    end
  end

  # The whole point of the bridge: a client that walks this flow ends up holding
  # something that works against the MCP endpoint it was trying to reach.
  describe "the issued token against the MCP endpoint" do
    it "authenticates a real MCP call" do
      expect(@result.fetch("mcp_with_issued_token_status")).to eq(200)
      expect(@result.fetch("mcp_with_issued_token_body")).to include("result")
    end
  end
end
