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

    # Nothing above configured a signing secret: on a Rails host it must resolve
    # to secret_key_base by itself, or every host would have to wire one.
    result["signing_secret_resolves_from_rails"] =
      McpToolkit.config.oauth_signing_secret == app.secret_key_base
    result["bridge_enabled"] = McpToolkit.config.oauth_bridge?

    # 1. An unauthenticated MCP call must point the client at the metadata.
    session.post("/mcp", JSON.generate({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
                 "CONTENT_TYPE" => "application/json")
    result["unauthenticated_status"] = session.last_response.status
    result["www_authenticate"] = session.last_response.headers["WWW-Authenticate"]

    # 2 + 3. Discovery, at the PATH-SCOPED locations (RFC 9728 §3.1 / RFC 8414 §3.1).
    session.get("/.well-known/oauth-protected-resource/mcp")
    result["prm_status"] = session.last_response.status
    result["prm"] = JSON.parse(session.last_response.body)
    result["prm_cache_control"] = session.last_response.headers["Cache-Control"]

    session.get("/.well-known/oauth-authorization-server/mcp")
    result["as_status"] = session.last_response.status
    result["as"] = JSON.parse(session.last_response.body)
    result["as_cache_control"] = session.last_response.headers["Cache-Control"]

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
    verifier  = "e2e-high-entropy-code-verifier-value-of-legal-length" # RFC 7636 §4.1: 43-128 chars
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

    # 10. A LOOPBACK client (RFC 8252 §7.3), whose ephemeral port no host could
    # have allowlisted ahead of time. Off until the host opts in, so prove both
    # states through the real stack rather than trusting the unit's fake host.
    loopback_uri = "http://127.0.0.1:54321/cb"
    loopback_query = authorize_query.merge(redirect_uri: loopback_uri)
    session.get("/mcp/oauth/authorize", loopback_query)
    result["loopback_authorize_status_when_off"] = session.last_response.status

    McpToolkit.config.oauth_allow_loopback_redirects = true
    session.get("/mcp/oauth/authorize", loopback_query)
    result["loopback_authorize_status_when_on"] = session.last_response.status

    session.post("/mcp/oauth/authorize", loopback_query.merge(access_token: VALID_TOKEN))
    result["approve_redirect_status"] = session.last_response.status
    loopback_location = session.last_response.headers["Location"]
    result["loopback_location_prefix"] = loopback_location && loopback_location.split("?").first
    loopback_code = loopback_location && Rack::Utils.parse_query(URI.parse(loopback_location).query)["code"]

    session.post("/mcp/oauth/token", {
      grant_type: "authorization_code", code: loopback_code, redirect_uri: loopback_uri, code_verifier: verifier
    })
    result["loopback_token_is_the_pasted_token"] = JSON.parse(session.last_response.body)["access_token"] == VALID_TOKEN
    result["token_cache_control"] = session.last_response.headers["Cache-Control"]
    result["token_pragma"] = session.last_response.headers["Pragma"]

    # Allowing loopback must widen NOTHING else. A registered network scheme names
    # a REMOTE host and would carry the code off the device; a private-use scheme
    # is a fixed string that belongs in the allowlist; and the remote allowlist is
    # the phishing target and stays named-only.
    {
      "ssh_status" => "ssh://attacker.example/cb",
      "gopher_status" => "gopher://attacker.example/cb",
      "ldap_status" => "ldap://attacker.example/cb",
      "private_scheme_status" => "cursor://anysphere.cursor-retrieval/oauth/callback",
      "remote_unregistered_status" => "https://attacker.example/x"
    }.each do |key, uri|
      session.get("/mcp/oauth/authorize", authorize_query.merge(redirect_uri: uri))
      result[key] = session.last_response.status
    end

    # 11. A format must not reach the action by EITHER route — a `.json` suffix or
    # an `Accept` header. There is no JSON template, so both would raise
    # unauthenticated. The suffix was fixed first; the header is the same hole.
    session.get("/mcp/oauth/authorize.json", authorize_query)
    result["authorize_json_suffix_status"] = session.last_response.status

    session.get("/mcp/oauth/authorize", authorize_query, "HTTP_ACCEPT" => "application/json")
    result["authorize_json_accept_status"] = session.last_response.status

    # 11b. And the bad-paste page must be a real 422, not a 500. `:unprocessable_content`
    # raises below Rack 3.1 and the gemspec declares no floor.
    session.post("/mcp/oauth/authorize", authorize_query.merge(access_token: "nope"))
    result["bad_paste_status"] = session.last_response.status
    session.post("/mcp/oauth/authorize", authorize_query.merge(access_token: "nope"),
                 "HTTP_ACCEPT" => "application/json")
    result["bad_paste_json_accept_status"] = session.last_response.status

    # 12. A loopback client controls its own query, so it can pass `?code=`. The
    # response owns that parameter — ours must be the only one.
    polluted = "http://127.0.0.1:54321/cb?code=ATTACKER&tenant=acme"
    session.post("/mcp/oauth/authorize",
                 authorize_query.merge(redirect_uri: polluted, access_token: VALID_TOKEN))
    polluted_location = session.last_response.headers["Location"]
    polluted_query = Rack::Utils.parse_query(URI.parse(polluted_location.to_s).query)
    result["polluted_code_values"] = Array(polluted_query["code"])
    result["polluted_keeps_client_query"] = polluted_query["tenant"]

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

  # Both documents name the authorization_endpoint an operator is sent to, and
  # both are built from the caller-influenced request origin — so a shared cache
  # holding one on another client's behalf is a token-theft primitive. Asserted
  # through real Rails because Rails writes its own Cache-Control on commit, and
  # a fake controller could only ever confirm the fake.
  describe "metadata cacheability" do
    it "forbids a shared cache from storing either document" do
      expect(@result.fetch("prm_cache_control")).to eq("no-store")
      expect(@result.fetch("as_cache_control")).to eq("no-store")
    end
  end

  # Loopback (RFC 8252 §7.3) is the one target that cannot be named ahead of time
  # — the client picks an ephemeral port at runtime — and the one that need not be,
  # since the code goes to the operator's own machine.
  describe "loopback (RFC 8252) clients" do
    it "refuses loopback until the host opts in" do
      expect(@result.fetch("loopback_authorize_status_when_off")).to eq(400)
    end

    it "runs a loopback client through the whole flow once opted in" do
      expect(@result.fetch("loopback_authorize_status_when_on")).to eq(200)
      expect(@result.fetch("loopback_location_prefix")).to eq("http://127.0.0.1:54321/cb")
      expect(@result.fetch("loopback_token_is_the_pasted_token")).to be(true)
    end

    # Allowing loopback widens loopback and nothing else. A scheme judged local
    # merely by its absence from a denylist is how `ssh://attacker.example` would
    # carry the code straight off the device.
    it "refuses registered network schemes, which name a remote host" do
      expect(@result.fetch("ssh_status")).to eq(400)
      expect(@result.fetch("gopher_status")).to eq(400)
      expect(@result.fetch("ldap_status")).to eq(400)
    end

    it "refuses an unnamed private-use scheme, which is a fixed string to allowlist" do
      expect(@result.fetch("private_scheme_status")).to eq(400)
    end

    it "keeps a remote callback allowlist-only even with loopback allowed" do
      expect(@result.fetch("remote_unregistered_status")).to eq(400)
    end
  end

  # A Rails host must not have to wire a signing secret: secret_key_base is
  # already the "server-held, in ENV, never logged" value the sealing wants.
  describe "the signing secret" do
    it "resolves from the Rails app's secret_key_base with no configuration" do
      expect(@result.fetch("signing_secret_resolves_from_rails")).to be(true)
      expect(@result.fetch("bridge_enabled")).to be(true)
    end
  end

  describe "request shapes that must not reach an action" do
    it "does not serve a format suffix the bridge never speaks" do
      expect(@result.fetch("authorize_json_suffix_status")).to eq(404)
    end

    # The `.json` suffix and an `Accept` header pick the format equally; closing
    # only the one a reviewer named would leave its twin open.
    it "renders the page regardless of what the caller says it accepts" do
      expect(@result.fetch("authorize_json_accept_status")).to eq(200)
    end
  end

  # A mistyped paste is the one thing this page exists to handle gracefully, and
  # it must not depend on a Rack version the gemspec never pinned.
  describe "the bad-paste page" do
    it "is a real 422 on any Rack, whatever the caller accepts" do
      expect(@result.fetch("bad_paste_status")).to eq(422)
      expect(@result.fetch("bad_paste_json_accept_status")).to eq(422)
    end
  end

  # A loopback redirect_uri is not exact-matched, so its query is the caller's to
  # choose. The parameters this response owns are not.
  describe "a loopback redirect_uri carrying its own code" do
    it "emits exactly one code, ours, and keeps the client's own query" do
      codes = @result.fetch("polluted_code_values")

      expect(codes.size).to eq(1)
      expect(codes.first).not_to eq("ATTACKER")
      expect(@result.fetch("polluted_keeps_client_query")).to eq("acme")
    end
  end

  # RFC 6749 §5.1 (both headers on a token response) and RFC 9700 §4.12 (303 after
  # a POST that carried a credential), asserted through the real stack.
  describe "token-bearing responses" do
    it "forbids caching the token response" do
      expect(@result.fetch("token_cache_control")).to eq("no-store")
      expect(@result.fetch("token_pragma")).to eq("no-cache")
    end

    it "redirects with 303 after the paste, so the token body is not resent" do
      expect(@result.fetch("approve_redirect_status")).to eq(303)
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
    # 303, not 302: this POST carried the token in its body, and only 303 tells the
    # browser unambiguously to GET the callback without resending it.
    it "redirects back to the client with the echoed state" do
      expect(@result.fetch("approve_status")).to eq(303)
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
