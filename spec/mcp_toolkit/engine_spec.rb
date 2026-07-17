# frozen_string_literal: true

require "spec_helper"

# The mountable engine + gem-provided controller are Rails-only and live outside
# the gem's lib-rooted Zeitwerk loader (engine.rb is ignored; the controller is an
# engine `app/controllers` path). The gem's suite runs WITHOUT Rails, so these
# examples stub the minimal surface each file touches rather than booting Rails:
#
#   * the engine subclasses ::Rails::Engine and calls `isolate_namespace` +
#     `routes.draw` — we stub a recorder to capture the drawn routes;
#   * the controller subclasses `config.parent_controller.constantize` and
#     includes the transport concern — we point parent_controller at a fake
#     ActionController-like base providing the class methods the concern calls.
#
# Constants are defined in `before` and torn down in `after` so they don't leak
# into the rest of the suite (which asserts Rails-absent behavior).
RSpec.describe "Mountable engine + gem controller" do
  describe "McpToolkit::ServerController (engine controller)" do
    # A fake ActionController::Base: provides only the class-level hooks the
    # transport concerns' `included do` blocks invoke.
    let(:auth_role) { :satellite }

    before do
      stub_const("FakeActionControllerBase", Class.new do
        def self.before_action(*); end
        def self.after_action(*); end
        # The concerns guard protect_from_forgery / rescue_from behind respond_to?;
        # omit them so those branches are exercised (no CSRF/rescue machinery
        # needed in a unit test).
      end)
      McpToolkit.config.parent_controller = "FakeActionControllerBase"
      McpToolkit.config.auth_role = auth_role

      # The engine controllers are no longer files: they are built lazily from the
      # configured parent + role by the builder (Constraint B). Build them explicitly.
      McpToolkit.build_engine_controllers!
    end

    after { McpToolkit.reset_engine_controllers! }

    it "inherits the configured parent_controller" do
      expect(McpToolkit::ServerController.superclass).to eq(FakeActionControllerBase)
    end

    it "exposes the transport actions wired by the concern" do
      expect(McpToolkit::ServerController.instance_methods).to include(:create, :stream, :destroy, :health)
    end

    context "when the host is a satellite (the default role)" do
      it "mounts the SDK-backed transport concern" do
        expect(McpToolkit::ServerController.include?(McpToolkit::Transport::ControllerMethods)).to be(true)
        expect(McpToolkit::ServerController.include?(McpToolkit::Authority::ControllerMethods)).to be(false)
      end
    end

    context "when the host is an authority" do
      let(:auth_role) { :authority }

      it "mounts the hand-rolled authority transport concern (so `mount` works for an authority)" do
        expect(McpToolkit::ServerController.include?(McpToolkit::Authority::ControllerMethods)).to be(true)
        expect(McpToolkit::ServerController.include?(McpToolkit::Transport::ControllerMethods)).to be(false)
      end
    end

    # The bridge's parent (default ActionController::Base) must not be
    # constantized on a host that never enables it: that would pull view
    # machinery into an API-only app and break a non-Rails host outright. Its
    # absence here is what proves the build is skipped — this whole suite runs
    # without Rails, so a constantize would raise NameError.
    it "does not build the OAuth controller when the bridge is off" do
      expect(McpToolkit.const_defined?(:OauthController, false)).to be(false)
    end
  end

  describe "McpToolkit::Engine routes" do
    # A recorder standing in for the engine's route set: captures each verb call
    # as [verb, path, to] so we can assert the endpoints are drawn. The routes
    # live in the engine's config/routes.rb (drawn through the routes_reloader so
    # they survive route reloads), so we load THAT file against the recorder.
    let(:route_recorder) do
      Class.new do
        attr_reader :drawn

        def initialize
          @drawn = []
        end

        def draw(&block)
          instance_eval(&block)
        end

        # `format:` is recorded separately (see `drawn_formats`): the bridge's
        # routes must disable Rails' optional format segment, and a recorder that
        # swallowed the option would let that regress unseen.
        %i[post get delete].each do |verb|
          define_method(verb) do |path, to:, **options|
            @drawn << [verb, path, to]
            (@formats ||= {})[[verb, path]] = options[:format]
          end
        end

        def drawn_formats
          @formats ||= {}
        end
      end.new
    end

    # The role decides whether the authority-only introspection route is drawn.
    # Default to :authority so the full endpoint set is asserted; the satellite
    # context below covers the gated-off case.
    let(:auth_role) { :authority }
    # The OAuth bridge is off until a host names who may receive an authorization
    # code, so it stays out of the default endpoint set.
    let(:oauth_redirect_uris) { [] }
    let(:oauth_allow_native) { false }
    # The bridge also needs the authenticator it verifies a pasted token with; an
    # authority always has one. Its own gate is asserted below.
    let(:token_authenticator) { ->(_plaintext) { nil } }
    # No Rails in this suite, so the secret_key_base default cannot resolve; the
    # gate's own requirement for it is asserted separately below.
    let(:oauth_signing_secret) { "spec-oauth-signing-secret-at-least-32-bytes-long" }

    before do
      McpToolkit.config.auth_role = auth_role
      McpToolkit.config.oauth_allowed_redirect_uris = oauth_redirect_uris
      McpToolkit.config.oauth_allow_loopback_redirects = oauth_allow_native
      McpToolkit.config.token_authenticator = token_authenticator
      McpToolkit.config.oauth_signing_secret = oauth_signing_secret
      recorder = route_recorder
      stub_const("Rails", Module.new)
      # The engine class body now also calls `config.to_prepare { ... }` (lazy
      # controller reset), so the fake base must expose a `config` responding to
      # `to_prepare` (a no-op here — nothing is reloaded in this unit test).
      config_double = Class.new { def to_prepare(*); end }.new
      engine_base = Class.new do
        define_singleton_method(:isolate_namespace) { |_mod| }
        # The engine also registers an initializer (filter_parameters for the
        # bridge's token-bearing params); recorded, not run — this unit boots no app.
        define_singleton_method(:initializer) { |name, &block| (@initializers ||= {})[name] = block }
        define_singleton_method(:initializers) { @initializers ||= {} }
      end
      engine_base.define_singleton_method(:config) { config_double }
      stub_const("Rails::Engine", engine_base)

      load File.expand_path("../../lib/mcp_toolkit/engine.rb", __dir__)
      # The engine class itself no longer draws routes; config/routes.rb does, via
      # McpToolkit::Engine.routes.draw — point that at the recorder.
      McpToolkit::Engine.define_singleton_method(:routes) { recorder }
      load File.expand_path("../../config/routes.rb", __dir__)
    end

    after { McpToolkit.send(:remove_const, :Engine) if McpToolkit.const_defined?(:Engine, false) }

    # The four transport endpoints are drawn for every role.
    transport_routes = [
      [:post, "/", "server#create"],
      [:get, "/", "server#stream"],
      [:delete, "/", "server#destroy"],
      [:get, "health", "server#health"]
    ]

    it "draws the transport endpoints plus the introspection route for an authority" do
      expect(route_recorder.drawn).to contain_exactly(
        *transport_routes,
        [:post, "tokens/introspect", "tokens#introspect"]
      )
    end

    context "when configured as a satellite (the default role)" do
      let(:auth_role) { :satellite }

      it "draws the transport endpoints but NOT the authority introspection route" do
        expect(route_recorder.drawn).to contain_exactly(*transport_routes)
      end
    end

    oauth_routes = [
      [:get, "oauth/authorize", "oauth#authorize"],
      [:post, "oauth/authorize", "oauth#approve"],
      [:post, "oauth/token", "oauth#token"],
      [:post, "oauth/register", "oauth#register"]
    ]

    it "does NOT draw the OAuth bridge for an authority that has not opted in" do
      expect(route_recorder.drawn).not_to include(*oauth_routes)
    end

    context "when the OAuth bridge is configured on an authority" do
      let(:oauth_redirect_uris) { ["https://client.example/callback"] }

      it "draws the bridge's endpoints" do
        expect(route_recorder.drawn).to include(*oauth_routes)
      end

      # Without this, Rails' optional `(.:format)` matches and
      # `/mcp/oauth/authorize.json` reaches the action, finds no JSON template and
      # 500s — an unauthenticated error for a format the bridge never speaks.
      it "disables the format segment on every bridge endpoint" do
        formats = oauth_routes.map { |verb, path, _| route_recorder.drawn_formats[[verb, path]] }

        expect(formats).to all(be(false))
      end
    end

    # Allowing native clients names who may receive a code just as an allowlist
    # entry does ("anything on my operators' machines"), so it is an opt-in in its
    # own right — a host serving only desktop MCP clients needs no allowlist.
    context "when an authority allows native clients but names no allowlist" do
      let(:oauth_allow_native) { true }

      it "draws the bridge's endpoints" do
        expect(route_recorder.drawn).to include(*oauth_routes)
      end
    end

    # The bridge verifies the pasted token through the authenticator on both legs,
    # so without one it cannot work. Drawing no route at all beats an authorization
    # page that takes an operator's token and then errors.
    context "when an authority named a redirect target but configured no token_authenticator" do
      let(:oauth_redirect_uris) { ["https://client.example/callback"] }
      let(:token_authenticator) { nil }

      # Still an authority, so its introspection route is unaffected — it is only
      # the bridge that goes away.
      it "still draws no OAuth bridge" do
        expect(route_recorder.drawn).not_to include(*oauth_routes)
      end
    end

    # Without a server-held secret the bridge cannot seal a code's payload, and
    # must not fall back to sealing it with something weaker. A Rails host never
    # sees this — it inherits secret_key_base.
    context "when an authority has no signing secret to resolve" do
      let(:oauth_redirect_uris) { ["https://client.example/callback"] }
      let(:oauth_signing_secret) { nil }

      it "still draws no OAuth bridge" do
        expect(route_recorder.drawn).not_to include(*oauth_routes)
      end
    end

    # The flow hands back a token this app authenticates itself; a satellite's
    # tokens belong to its central app, so there is nothing for it to authorize
    # against — an allowlist alone must not switch the bridge on.
    context "when a satellite configures a redirect allowlist" do
      let(:auth_role) { :satellite }
      let(:oauth_redirect_uris) { ["https://client.example/callback"] }

      it "still draws no OAuth bridge" do
        expect(route_recorder.drawn).to contain_exactly(*transport_routes)
      end
    end

    it "subclasses ::Rails::Engine" do
      expect(McpToolkit::Engine.superclass).to eq(Rails::Engine)
    end
  end
end
