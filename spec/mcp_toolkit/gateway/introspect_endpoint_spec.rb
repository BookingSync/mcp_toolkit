# frozen_string_literal: true

require "spec_helper"

# Request spec for the gem-provided authority introspection endpoint
# (McpToolkit::TokensController#introspect), routed through McpToolkit::Engine at
# POST /mcp/tokens/introspect.
#
# The controller lives under the gem's app/controllers (an engine path) and calls
# ActionController methods (`request.headers`, `params`, `render`), so — like the
# engine route-reload regression — it can only be exercised against a REAL Rails
# app. Booting Rails in-process irreversibly mutates global state and would
# contaminate this otherwise Rails-absent suite across random orderings, so the
# boot runs in an ISOLATED CHILD Ruby process: it boots a minimal app configured
# as an authority, mounts the engine, dispatches a handful of requests through the
# full Rack stack, and prints each response's [status, parsed-body] as one JSON
# line for this parent to assert on.
#
# Rails-only: railties/actionpack are a TEST dependency (see Gemfile), skipped
# when Rails is unavailable.
rails_available =
  begin
    require "rails/version"
    true
  rescue LoadError
    false
  end

RSpec.describe "Authority introspection endpoint (via the engine)", if: rails_available do
  INTROSPECT_DRIVER = <<~'RUBY'
    require "bundler/setup"
    require "json"
    require "tmpdir"
    require "logger"
    require "mcp_toolkit"
    require "rails"
    require "action_controller/railtie"
    require "rack/mock"

    # A token object matching the gem's duck-typed authority contract.
    token_class = Struct.new(:kind, :account_id, :account_ids, :expires_at, :scopes, keyword_init: true) do
      def touch_last_used! = nil
    end
    valid_token = token_class.new(
      kind: "accounts_user", account_id: 42, account_ids: [42],
      expires_at: Time.utc(2026, 12, 31), scopes: ["notifications__read"]
    )

    McpToolkit.configure do |c|
      c.parent_controller  = "ActionController::Base"
      c.auth_role          = :authority
      c.token_authenticator = ->(plaintext) { plaintext == "good" ? valid_token : nil }
    end

    # mcp_toolkit was required before Rails, so load the (Zeitwerk-ignored) engine
    # by path.
    unless McpToolkit.const_defined?(:Engine, false)
      load File.expand_path("lib/mcp_toolkit/engine.rb", Dir.pwd)
    end

    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.consider_all_requests_local = true
      config.secret_key_base = "introspect-spec-secret-key-base"
      config.logger = Logger.new(IO::NULL)
      config.root = Dir.mktmpdir("mcp_toolkit_introspect_spec")
      # Rack::MockRequest posts from host "example.org"; disable Rails 8's host
      # authorization so the request isn't blocked with a 403.
      config.hosts.clear
    end
    app.initialize!
    app.routes.draw { mount McpToolkit::Engine => "/mcp" }

    rack = Rack::MockRequest.new(app)
    path = "/mcp/tokens/introspect"

    call = lambda do |opts|
      res = rack.post(opts.fetch(:path, path), opts.fetch(:env, {}))
      body = res.body.to_s.empty? ? nil : JSON.parse(res.body)
      { "status" => res.status, "body" => body }
    end

    result = {
      "valid_bearer"   => call.call(env: { "HTTP_AUTHORIZATION" => "Bearer good" }),
      "invalid_bearer" => call.call(env: { "HTTP_AUTHORIZATION" => "Bearer nope" }),
      "missing_token"  => call.call(env: {}),
      "x_mcp_token"    => call.call(env: { "HTTP_X_MCP_TOKEN" => "good" }),
      "query_token"    => call.call(path: "#{path}?token=good"),
    }

    # Unconfigured-authority case: drawing the route is safe even with no
    # token_authenticator -> {valid:false} rather than a 500.
    McpToolkit.config.token_authenticator = nil
    result["unconfigured"] = call.call(env: { "HTTP_AUTHORIZATION" => "Bearer good" })

    puts JSON.generate(result)
  RUBY

  before(:all) do
    require "json"
    require "open3"

    gem_root = File.expand_path("../../..", __dir__)
    stdout, stderr, status = Open3.capture3(Gem.ruby, "-e", INTROSPECT_DRIVER, chdir: gem_root)
    raise "introspect endpoint driver failed (#{status.exitstatus}):\n#{stderr}" unless status.success?

    @result = JSON.parse(stdout.lines.last)
  end

  it "returns the exact introspection payload for a valid Bearer token (200)" do
    valid = @result.fetch("valid_bearer")

    expect(valid.fetch("status")).to eq(200)
    expect(valid.fetch("body")).to eq(
      "valid" => true,
      "kind" => "accounts_user",
      "account_id" => 42,
      "account_ids" => [42],
      "expires_at" => "2026-12-31T00:00:00Z",
      "scopes" => ["notifications__read"]
    )
  end

  it "returns { valid: false } with 401 for an invalid token" do
    invalid = @result.fetch("invalid_bearer")

    expect(invalid.fetch("status")).to eq(401)
    expect(invalid.fetch("body")).to eq("valid" => false)
  end

  it "returns { valid: false } with 401 when no token is presented" do
    missing = @result.fetch("missing_token")

    expect(missing.fetch("status")).to eq(401)
    expect(missing.fetch("body")).to eq("valid" => false)
  end

  it "accepts the token via the X-MCP-Token header" do
    expect(@result.fetch("x_mcp_token")).to match("status" => 200, "body" => a_hash_including("valid" => true))
  end

  it "accepts the token via the ?token= query param" do
    expect(@result.fetch("query_token")).to match("status" => 200, "body" => a_hash_including("valid" => true))
  end

  it "answers { valid: false } (not a 500) when no token_authenticator is configured" do
    unconfigured = @result.fetch("unconfigured")

    expect(unconfigured.fetch("status")).to eq(401)
    expect(unconfigured.fetch("body")).to eq("valid" => false)
  end
end
