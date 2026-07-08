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
    before do
      stub_const("FakeActionControllerBase", Class.new do
        def self.before_action(*); end
        def self.after_action(*); end
        # The concern guards protect_from_forgery behind respond_to?; omit it so
        # that branch is exercised (no CSRF machinery needed in a unit test).
      end)
      McpToolkit.config.parent_controller = "FakeActionControllerBase"

      # The engine controllers are no longer files: they are built lazily from the
      # configured parent by the builder (Constraint B). Build them explicitly.
      McpToolkit.build_engine_controllers!
    end

    after { McpToolkit.reset_engine_controllers! }

    it "inherits the configured parent_controller" do
      expect(McpToolkit::ServerController.superclass).to eq(FakeActionControllerBase)
    end

    it "includes the standalone transport concern (the engine path is additive)" do
      expect(McpToolkit::ServerController.include?(McpToolkit::Transport::ControllerMethods)).to be(true)
    end

    it "exposes the transport actions wired by the concern" do
      expect(McpToolkit::ServerController.instance_methods).to include(:create, :stream, :destroy, :health)
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

        %i[post get delete].each do |verb|
          define_method(verb) { |path, to:| @drawn << [verb, path, to] }
        end
      end.new
    end

    # The role decides whether the authority-only introspection route is drawn.
    # Default to :authority so the full endpoint set is asserted; the satellite
    # context below covers the gated-off case.
    let(:auth_role) { :authority }

    before do
      McpToolkit.config.auth_role = auth_role
      recorder = route_recorder
      stub_const("Rails", Module.new)
      # The engine class body now also calls `config.to_prepare { ... }` (lazy
      # controller reset), so the fake base must expose a `config` responding to
      # `to_prepare` (a no-op here — nothing is reloaded in this unit test).
      config_double = Class.new { def to_prepare(*); end }.new
      engine_base = Class.new do
        define_singleton_method(:isolate_namespace) { |_mod| }
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

    it "subclasses ::Rails::Engine" do
      expect(McpToolkit::Engine.superclass).to eq(Rails::Engine)
    end
  end
end
