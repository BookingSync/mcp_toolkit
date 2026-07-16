# frozen_string_literal: true

# Lazy `parent_controller` builder (Constraint B).
#
# The engine's controllers (McpToolkit::ServerController,
# McpToolkit::TokensController) and the authority base
# (McpToolkit::Authority::ServerController) all subclass
# `config.parent_controller`. If that superclass were resolved in a class body of
# an autoloaded/eager-loaded file, it could be read BEFORE the host's
# initializer/to_prepare had set it — defaulting to ActionController::Base and, in
# turn, breaking CSRF handling on the introspection endpoint.
#
# Instead, none of these controllers is a Zeitwerk-managed file. They are built
# here from the CURRENT config, and the build is triggered LAZILY:
#   * `const_missing` (below, and on McpToolkit::Authority) builds them the first
#     time they are referenced — which, in a host, is at eager-load or first-
#     request time, i.e. AFTER the app's initializers/to_prepare have run;
#   * the engine's `config.to_prepare` RESETS them on every code reload so a
#     changed `parent_controller` (or a reloaded app parent class) takes effect on
#     the next reference.
#
# The whole `config/initializers/mcp_toolkit.rb` of a host can therefore live in
# `to_prepare`: the parent is only ever read at build time.
#
# This file reopens `McpToolkit` to add module methods, so it is Zeitwerk-IGNORED
# (like engine.rb) and required explicitly from the gem entry point.
module McpToolkit
  # The controllers built directly under McpToolkit (the engine's routes point at
  # these). McpToolkit::Authority::ServerController is built alongside them but is
  # fetched through McpToolkit::Authority's own const_missing.
  ENGINE_CONTROLLER_NAMES = %i[ServerController TokensController OauthController].freeze

  # (Re)builds the engine controllers + the authority base from the current
  # config. Idempotent: an existing constant is replaced so a rebuild reflects a
  # changed `parent_controller`. Reads `config.parent_controller` at call time.
  def self.build_engine_controllers!
    parent = config.parent_controller.constantize
    define_controller(self, :ServerController, build_server_controller(parent))
    define_controller(self, :TokensController, build_tokens_controller(parent))
    # Only when the bridge is on — matching its routes, which are equally gated.
    # Its parent (default ActionController::Base) would otherwise be constantized
    # on every host, pulling view machinery into an API-only app that never
    # enables the bridge, and breaking a non-Rails host outright.
    define_controller(self, :OauthController, build_oauth_controller) if config.oauth_bridge?
    define_controller(Authority, :ServerController, build_authority_server_controller(parent))
    ServerController
  end

  # Undefines the built controllers so the next reference rebuilds them from the
  # then-current config. Called from the engine's `to_prepare` on every reload.
  def self.reset_engine_controllers!
    ENGINE_CONTROLLER_NAMES.map { |name| [self, name] }.push([Authority, :ServerController]).each do |mod, name|
      mod.send(:remove_const, name) if mod.const_defined?(name, false)
    end
  end

  # The transport controller the engine mounts at POST/GET/DELETE /mcp, chosen by
  # ROLE so a single `mount McpToolkit::Engine => "/mcp"` works for either kind of
  # host: an AUTHORITY (`auth_role == :authority`) gets the hand-rolled dispatcher
  # path (Authority::ControllerMethods — local token auth, gateway proxying, usage
  # metering, rate limiting), a SATELLITE (the default) gets the SDK-backed path
  # (Transport::ControllerMethods, which forwards tokens to a central app). Built
  # lazily so both `config.parent_controller` and `config.auth_role` are read after
  # the host's initializer/to_prepare has run. A host that would rather draw its own
  # routes still subclasses McpToolkit::Authority::ServerController directly.
  def self.build_server_controller(parent)
    concern = config.authority? ? McpToolkit::Authority::ControllerMethods : McpToolkit::Transport::ControllerMethods
    Class.new(parent) { include concern }
  end

  # The AUTHORITY introspection endpoint the engine mounts at
  # `POST /mcp/tokens/introspect`. Behavior is preserved exactly: it authenticates
  # the bearer against `config.token_authenticator` (via Auth::Authority) and
  # renders the introspection payload; a non-authority app answers `{ valid:
  # false }` rather than erroring.
  def self.build_tokens_controller(parent)
    Class.new(parent) do
      def introspect
        token = McpToolkit::Auth::Authority.authenticate(mcp_extract_token, config: mcp_config)
        return render(json: McpToolkit::Auth::Authority.invalid_payload, status: :unauthorized) if token.nil?

        render json: McpToolkit::Auth::Authority.introspection_payload(token)
      rescue McpToolkit::Errors::ConfigurationError
        # Not configured as an authority (no token_authenticator): behave as if the
        # token were invalid instead of surfacing a 500.
        render json: McpToolkit::Auth::Authority.invalid_payload, status: :unauthorized
      end

      private

      def mcp_config
        McpToolkit.config
      end

      def mcp_extract_token
        auth_header = request.headers["Authorization"]
        return auth_header.sub("Bearer ", "") if auth_header&.start_with?("Bearer ")

        request.headers["X-MCP-Token"].presence || params[:token].presence
      end
    end
  end

  # The OAuth authorization bridge the engine mounts at `<mcp>/oauth/*` and the
  # host draws at the two `.well-known` metadata paths.
  #
  # Built from `config.oauth_parent_controller`, NOT the `parent_controller` its
  # siblings use: the transport is a JSON-only endpoint that a host rightly points
  # at ActionController::API, which cannot render an HTML view — and this
  # controller's authorization page is one. Sharing the parent would force a host
  # to weaken its transport's superclass just to enable the bridge. Read lazily
  # here, like the rest, so the host's initializer/to_prepare has already run.
  def self.build_oauth_controller
    Class.new(config.oauth_parent_controller.constantize) { include McpToolkit::Oauth::ControllerMethods }
  end

  # The AUTHORITY base controller a host subclasses (the recommended path for a
  # host whose rate-limit/usage/account hooks touch app models).
  def self.build_authority_server_controller(parent)
    Class.new(parent) { include McpToolkit::Authority::ControllerMethods }
  end

  # Draws the OAuth bridge's two metadata documents. A `/.well-known/*` path
  # cannot be drawn by an engine mounted under a path, so it has to live in the
  # host's own route set. The host calls this at the TOP LEVEL — not inside a
  # locale/format/constraint scope, which would prefix the paths out of view:
  #
  #   # config/routes.rb
  #   Rails.application.routes.draw do
  #     McpToolkit.draw_oauth_metadata_routes(self)
  #     mount McpToolkit::Engine => "/mcp"
  #     # ...
  #   end
  #
  # The paths are PATH-SCOPED to the engine's mount
  # (`/.well-known/oauth-protected-resource/mcp`), so this claims NOTHING
  # origin-global and cannot collide with an OAuth provider the host already runs
  # — see Configuration#oauth_protected_resource_path for why that matters. A host
  # mounted at its origin root gets the bare paths instead, which is correct there.
  #
  # A no-op unless the bridge is configured, so the call can sit in a host's routes
  # unconditionally across environments.
  def self.draw_oauth_metadata_routes(mapper)
    return unless config.oauth_bridge?

    mapper.get config.oauth_protected_resource_path,
               to: "mcp_toolkit/oauth#protected_resource", format: false
    mapper.get config.oauth_authorization_server_path,
               to: "mcp_toolkit/oauth#authorization_server", format: false
  end

  # Removes an existing same-named constant (avoiding a redefinition warning on a
  # rebuild) before setting the freshly-built class.
  def self.define_controller(mod, name, klass)
    mod.send(:remove_const, name) if mod.const_defined?(name, false)
    mod.const_set(name, klass)
  end

  # Backstop: build the engine controllers the first time one is referenced before
  # any `to_prepare`/eager-load pass has built them (e.g. a bespoke route that
  # names McpToolkit::ServerController directly). McpToolkit::Authority defines the
  # sibling backstop for its ServerController.
  def self.const_missing(name)
    if ENGINE_CONTROLLER_NAMES.include?(name)
      build_engine_controllers!
      return const_get(name) if const_defined?(name, false)
    end

    super
  end
end
