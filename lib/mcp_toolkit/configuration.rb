# frozen_string_literal: true

require "active_support/cache"

module McpToolkit
  # The single, injectable configuration object for an app's MCP server.
  #
  # Generic but OPINIONATED: every setting has a default that matches exactly how
  # bsa-notifications / BookingSync already work, so a satellite needs to override
  # only a handful of values. The two things an app almost always sets are
  # `server_name` and the auth wiring (`central_app_url` + `required_application`
  # for a satellite, or `token_authenticator` for the authority).
  #
  # Accessed through `McpToolkit.config` (or `MCPToolkit.config`) and mutated in a
  # `McpToolkit.configure { |c| ... }` block.
  class Configuration
    # --- server identity -------------------------------------------------------

    # @return [String] the MCP server name advertised in `initialize`.
    attr_accessor :server_name
    # @return [String] the MCP server version advertised in `initialize`.
    attr_accessor :server_version
    # @return [String, nil] human-readable `instructions` returned on `initialize`.
    attr_accessor :server_instructions

    # --- serialization ---------------------------------------------------------

    # The DEFAULT serializer base class. A `Resource` registration that does not
    # supply its own `serializer` inherits nothing here — serializers are picked
    # per-resource — but this is the class the gem ships and documents as the base
    # to subclass. Apps that want BookingSync's API-v3 / Prometheus-derived
    # serializers simply register resources with those classes instead; the gem
    # only requires that a serializer responds to `serialize_one` /
    # `serialize_collection` (see McpToolkit::Serializer::Base for the contract).
    #
    # @return [Class]
    # The reader is defined below as a lazily-defaulting method; only the writer
    # comes from here.
    attr_writer :serializer_base

    # --- auth: role ------------------------------------------------------------

    # @return [Symbol] :satellite (introspect tokens against a central app) or
    #   :authority (be the introspection provider + authenticate local tokens).
    #   A single app MAY be both — set :authority and still configure a
    #   `central_app_url` if it also exposes its own tools as a satellite.
    attr_accessor :auth_role

    # --- auth: satellite side --------------------------------------------------

    # @return [String, nil] base URL of the central auth app (e.g. BookingSync).
    #   The satellite POSTs `<central_app_url>/mcp/tokens/introspect`.
    attr_accessor :central_app_url
    # @return [String, nil] the introspect path appended to `central_app_url`.
    attr_accessor :introspect_path
    # @return [String, nil] the application key a token MUST be scoped to for this
    #   satellite (bsa-notifications' "notifications"). When nil, the application
    #   scope check is skipped (any valid token is accepted).
    attr_accessor :required_application
    # @return [Integer] seconds to cache an introspection result (positive AND
    #   negative) so a burst of tool calls does not hammer the central app.
    attr_accessor :introspection_cache_ttl
    # @return [Integer] HTTP open/read timeout for the introspection call.
    attr_accessor :introspection_timeout

    # Resolves the central account id to the satellite's LOCAL scope root.
    #
    # A satellite stores rows keyed by the central app's account id (synced via
    # Kafka etc.). This callable receives the resolved central `account_id` and
    # MUST return the object that `Resource#scope` blocks root on (typically the
    # local `Account`). Return nil to signal "no local account" (=> Unauthorized).
    #
    #   c.account_resolver = ->(synced_account_id) { Account.find_by(synced_id: synced_account_id) }
    #
    # Defaults to the identity function: the resolved central account id is used
    # directly as the scope root (suitable for an app whose scope blocks key on the
    # central id, or for the authority itself).
    #
    # @return [#call]
    attr_accessor :account_resolver

    # --- auth: authority side --------------------------------------------------

    # Looks up + verifies a plaintext bearer token locally, returning a token
    # object (duck-typed, see below) or nil. This is the authority's
    # `McpToken.authenticate(plaintext)` equivalent. Required for the :authority
    # role; unused by a pure satellite.
    #
    #   c.token_authenticator = ->(plaintext) { McpToken.authenticate(plaintext) }
    #
    # The returned token object must respond to the methods
    # `McpToolkit::Auth::IntrospectionPayload` reads (see that class for the
    # contract): `kind`, `account_id`, `account_ids`, `expires_at`,
    # `application_keys`. A `touch_last_used!` method, if present, is called.
    #
    # @return [#call, nil]
    attr_accessor :token_authenticator

    # --- caching ---------------------------------------------------------------

    # The cache store backing sessions and introspection results. Must satisfy the
    # ActiveSupport::Cache::Store contract (`read`/`write`/`delete` with
    # `expires_in:`). Defaults to an in-process MemoryStore; a real deployment
    # should set this to `Rails.cache` (or any shared store) so sessions survive
    # across Puma workers.
    #
    # @return [ActiveSupport::Cache::Store, #read]
    attr_accessor :cache_store

    # @return [Integer] session sliding-TTL in seconds.
    attr_accessor :session_ttl

    # --- protocol / transport --------------------------------------------------

    # @return [String, nil] protocol version to pin on the underlying MCP::Server.
    #   nil lets the gem negotiate (recommended). Set only to force an older spec.
    attr_accessor :protocol_version

    # Header / meta-key constants. Generic defaults match both apps; an app on a
    # different central authority can rename them. These are the selectors a
    # superuser/multi-account token uses to pin the active account.
    #
    # @return [String]
    attr_accessor :account_meta_key
    # @return [String]
    attr_accessor :account_id_header

    # The resource registry for this configuration. Each config carries its own so
    # tests (and, in principle, multiple mounted servers) don't collide. The
    # process-wide convenience `McpToolkit.registry` delegates to the active
    # config's registry.
    #
    # @return [McpToolkit::Registry]
    attr_accessor :registry

    # Defaults mirror exactly how bsa-notifications + BookingSync are wired today.
    def initialize
      @server_name = "mcp-server"
      @server_version = "1.0.0"
      @server_instructions = nil

      @serializer_base = nil # set lazily in #serializer_base to avoid load-order issues

      @auth_role = :satellite
      @central_app_url = nil
      @introspect_path = "/mcp/tokens/introspect"
      @required_application = nil
      @introspection_cache_ttl = 45
      @introspection_timeout = 10
      @account_resolver = ->(synced_account_id) { synced_account_id }

      @token_authenticator = nil

      @cache_store = ActiveSupport::Cache::MemoryStore.new
      @session_ttl = 3600 # 1 hour

      @protocol_version = nil
      @account_meta_key = "bookingsync.com/account-id"
      @account_id_header = "X-BookingSync-Account-ID"

      @registry = McpToolkit::Registry.new
    end

    # The serializer base, lazily defaulting to the gem's bundled DSL base. Lazy so
    # `McpToolkit::Serializer::Base` is referenced after it has been required,
    # regardless of file load order.
    def serializer_base
      @serializer_base ||= McpToolkit::Serializer::Base
    end

    # @return [Boolean] whether this app introspects tokens against a central app.
    def satellite?
      auth_role.to_sym == :satellite || central_app_url
    end

    # @return [Boolean] whether this app authenticates tokens locally / answers
    #   introspection.
    def authority?
      auth_role.to_sym == :authority
    end

    # Full introspection URL the satellite POSTs to. Raises a clear error if the
    # central URL was never configured.
    def introspect_url
      raise Errors::ConfigurationError, "central_app_url is not configured" if central_app_url.to_s.empty?

      "#{central_app_url.chomp("/")}#{introspect_path}"
    end
  end
end
