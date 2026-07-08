# frozen_string_literal: true

# The single, injectable configuration object for an app's MCP server.
#
# Generic but OPINIONATED: every setting has a sensible, vendor-neutral default,
# so a satellite needs to override only a handful of values. The two things an
# app almost always sets are
# `server_name` and the auth wiring (`central_app_url` for a satellite, or
# `token_authenticator` for the authority).
#
# Whether ANY scope is required is decided PER TOOL, not per app: a resource
# declares `required_permissions_scope "notifications__read"` (or the registry
# declares `default_required_permissions_scope` once for all resources). There is
# no app-wide permission setting here.
#
# Accessed through `McpToolkit.config` (or `MCPToolkit.config`) and mutated in a
# `McpToolkit.configure { |c| ... }` block.
class McpToolkit::Configuration
  # --- server identity -------------------------------------------------------

  # @return [String] the MCP server name advertised in `initialize`.
  attr_accessor :server_name
  # @return [String] the MCP server version advertised in `initialize`.
  attr_accessor :server_version
  # @return [String, nil] human-readable `instructions` returned on `initialize`.
  attr_accessor :server_instructions

  # --- gateway client identity (identity split) ------------------------------

  # The `clientInfo` an app presents when it acts as a GATEWAY talking to its
  # upstream MCP servers (McpToolkit::Gateway::Client's handshake). Split from the
  # SERVER identity (`server_name`/`server_version`, advertised to the app's OWN
  # callers) so an authority can present its real server identity downstream while
  # keeping its upstream handshake byte-identical to a prior deployment. Both
  # default to the server identity, so a satellite/gateway that doesn't care sets
  # nothing.
  #
  #   c.server_name         = "acme-mcp"          # advertised to our callers
  #   c.gateway_client_name = "acme-mcp-gateway"  # presented to our upstreams
  #
  # @return [String] gateway handshake client name (defaults to `server_name`).
  attr_writer :gateway_client_name
  # @return [String] gateway handshake client version (defaults to `server_version`).
  attr_writer :gateway_client_version

  # --- serialization ---------------------------------------------------------

  # The DEFAULT serializer base class. A `Resource` registration that does not
  # supply its own `serializer` inherits nothing here — serializers are picked
  # per-resource — but this is the class the gem ships and documents as the base
  # to subclass. Apps that want their own existing serializers simply register
  # resources with those classes instead; the gem only requires that a serializer
  # responds to `serialize_one` / `serialize_collection` (see
  # McpToolkit::Serializer::Base for the contract).
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

  # @return [String, nil] base URL of the central auth app.
  #   The satellite POSTs `<central_app_url>/mcp/tokens/introspect`.
  attr_accessor :central_app_url
  # @return [String, nil] the introspect path appended to `central_app_url`.
  attr_accessor :introspect_path
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
  # `AccessToken.authenticate(plaintext)` equivalent. Required for the :authority
  # role; unused by a pure satellite.
  #
  #   c.token_authenticator = ->(plaintext) { AccessToken.authenticate(plaintext) }
  #
  # The returned token object must respond to the methods
  # `McpToolkit::Auth::Authority#introspection_payload` reads (see that module for
  # the contract): `kind`, `account_id`, `account_ids`, `expires_at`, `scopes`. A
  # `touch_last_used!` method, if present, is called.
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

  # --- rate limiting ---------------------------------------------------------

  # The built-in per-principal request cap enforced by the authority transport
  # (McpToolkit::Authority::ControllerMethods#mcp_rate_limit!), counted against
  # `cache_store` via McpToolkit::RateLimiter. nil (the default) DISABLES rate
  # limiting entirely, so a pure host is unaffected until it opts in. Set an
  # Integer to cap each principal to that many requests per `rate_limit_window`.
  # The default `mcp_rate_limit!` reads this through the overridable
  # `mcp_rate_limit_max_requests` hook, so a host that keeps the cap in its own
  # constant/model overrides that hook rather than this value.
  #
  # @return [Integer, nil]
  attr_accessor :rate_limit_max_requests

  # The fixed rate-limit window, in seconds (default 3600 = 1 hour). Ignored
  # while `rate_limit_max_requests` is nil.
  #
  # @return [Integer]
  attr_accessor :rate_limit_window

  # --- superuser (optional, first-class) -------------------------------------

  # Optional resolver deciding whether a principal is a SUPERUSER — a cross-tenant
  # caller that may reach `superusers_only!` resources. `->(principal) -> Boolean`.
  # When set, McpToolkit::Authority::Context#superuser? calls it; when nil (the
  # default) the context falls back to duck-typing `principal.superuser?` (false
  # when the principal doesn't respond to it). Superuser is FULLY OPTIONAL: a host
  # with no such concept leaves this nil and flags no `superusers_only!` resource,
  # so no caller is ever a superuser.
  #
  # @return [#call, nil]
  attr_accessor :superuser_resolver

  # --- filtering -------------------------------------------------------------

  # Escapes LIKE wildcards in `matches` / `does_not_match` filter values so they
  # match literally. Must respond to `sanitize_sql_like(string)`. Defaults to the
  # ActiveRecord-backed McpToolkit::SqlSanitizer; a non-Rails host (or a test) can
  # inject its own.
  #
  # @return [#sanitize_sql_like]
  attr_accessor :sql_sanitizer

  # --- protocol / transport --------------------------------------------------

  # @return [String, nil] protocol version to pin on the underlying MCP::Server.
  #   nil lets the gem negotiate (recommended). Set only to force an older spec.
  attr_accessor :protocol_version

  # The protocol versions the hand-rolled AUTHORITY dispatcher
  # (McpToolkit::Dispatcher) negotiates, newest first. `initialize` echoes the
  # requested version when it is in this set, else the first (latest). Defaults to
  # McpToolkit::Protocol::SUPPORTED_VERSIONS; override to pin a host's own set.
  #
  # @return [Array<String>]
  attr_accessor :supported_protocol_versions

  # The parent class (as a String, resolved via `constantize`) of the
  # gem-provided McpToolkit::ServerController that McpToolkit::Engine mounts.
  # Doorkeeper-style indirection so a satellite mounting the engine can keep
  # ActionController::Base (NOT ::API) — e.g. for a logstasher `helper_method`
  # hook — by setting `c.parent_controller = "ApplicationController"`.
  #
  # @return [String]
  attr_accessor :parent_controller

  # Header / meta-key constants. Vendor-neutral defaults; an app on a specific
  # central authority can rename them to match that authority's convention.
  # These are the selectors a superuser/multi-account token uses to pin the
  # active account.
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

  # --- gateway / upstreams ---------------------------------------------------

  # @return [Integer] HTTP open/read timeout (s) for a gateway's calls to an
  #   upstream MCP server (McpToolkit::Gateway::Client).
  attr_accessor :upstream_timeout
  # @return [Integer] TTL (s) for an upstream's cached, namespaced tool list in
  #   McpToolkit::Gateway::Aggregator.
  attr_accessor :upstream_list_ttl

  # The registry of upstream MCP servers this gateway aggregates + proxies to.
  # Each config carries its own (like `registry`), so it resets with a fresh
  # config. Register via the `register_upstream` sugar below or directly on this
  # instance. Empty unless the app registers upstreams, so a non-gateway app is
  # unaffected.
  #
  # @return [McpToolkit::Gateway::UpstreamRegistry]
  attr_reader :upstreams

  # --- authority hooks -------------------------------------------------------
  #
  # Injection points for the AUTHORITY transport (McpToolkit::Authority::
  # ControllerMethods) so a PURE host drives billing/tenancy from config without
  # subclassing. A host whose logic touches its own models overrides the matching
  # hook METHOD on its McpToolkit::Authority::ServerController subclass instead;
  # then these stay nil. All default to nil (a no-op).

  # OPTIONAL escape hatch that FULLY REPLACES the built-in limiter: a
  # `->(controller:, principal:)` that renders + halts when over the limit (or
  # sets rate-limit headers when under). When set, `mcp_rate_limit!` delegates to
  # it and the built-in (`rate_limit_max_requests`) is skipped. nil (the default)
  # means the built-in runs instead. Most hosts want the built-in; reach for this
  # only when the counting itself must live in app code.
  #
  # @return [#call, nil]
  attr_accessor :rate_limiter

  # Records ONE usage event for a single JSON-RPC call (called per batch element).
  # `->(request_data:, account:, principal:, controller:)`. MUST never affect the
  # MCP response. nil = no metering.
  #
  # @return [#call, nil]
  attr_accessor :usage_recorder

  # Persists accumulated usage after the response (an after_action).
  # `->(controller:)`. MUST never affect the MCP response. nil = no flush.
  #
  # @return [#call, nil]
  attr_accessor :usage_flusher

  # Builds the opaque payload bound to a session on `initialize`. `->(principal:)`
  # returning a Hash (or nil for none). Lets a host bind e.g.
  # `{ token_id: principal.id }` so a revoked token can kill an in-flight session,
  # WITHOUT overriding the controller's `mcp_session_data`. nil (the default) =>
  # an empty session payload.
  #
  # @return [#call, nil]
  attr_accessor :session_data_builder

  # The host's tool catalog — the api-agnostic seam. Duck-typed; the dispatcher
  # calls:
  #
  #   provider.tool_definitions(context) -> [{ name:, description:, inputSchema: }]
  #   provider.find(name)                -> a tool object, or nil
  #
  # where a tool object responds to `#required_permissions_scope` (String|nil, the
  # gem's scope gate) and `#call(context:, **arguments)` (returns Hash|String,
  # which the gem wraps into `{ content: [{ type: "text", text: }] }`). See
  # McpToolkit::Tools::AuthorityBase for a base that satisfies this. nil = the host
  # contributes no own tools (a pure gateway).
  #
  # @return [#tool_definitions, #find, nil]
  attr_accessor :tool_provider

  # --- generic tool naming ---------------------------------------------------

  # A prefix prepended to the four GENERIC, Registry-backed authority tool names
  # (`resources`, `resource_schema`, `get`, `list`) served by
  # McpToolkit::Authority::RegistryToolProvider. Lets a host NAMESPACE its generic
  # tools — e.g. set `"foo_"` and they advertise (and resolve) as `foo_resources`,
  # `foo_resource_schema`, `foo_get`, `foo_list` — so distinct MCP surfaces don't
  # collide and existing clients keep a stable, host-chosen name. Empty by default,
  # so the tools keep their bare base names. The prefix value is the host's; the gem
  # names no app concept.
  #
  # @return [String]
  attr_accessor :generic_tool_name_prefix

  # --- diagnostics -----------------------------------------------------------

  # Optional logger for gateway/session diagnostics. All call sites guard with
  # `logger&.warn` / `logger&.error`, so nil (the default) silences them. A Rails
  # host typically sets this to `Rails.logger`.
  #
  # @return [#warn, #error, nil]
  attr_accessor :logger

  # Vendor-neutral defaults; apps override the auth wiring + identity as needed.
  def initialize
    @server_name = "mcp-server"
    @server_version = "1.0.0"
    @server_instructions = nil

    @gateway_client_name = nil
    @gateway_client_version = nil

    @serializer_base = nil # set lazily in #serializer_base to avoid load-order issues

    @auth_role = :satellite
    @central_app_url = nil
    @introspect_path = "/mcp/tokens/introspect"
    @introspection_cache_ttl = 45
    @introspection_timeout = 10
    @account_resolver = ->(synced_account_id) { synced_account_id }

    @token_authenticator = nil

    @cache_store = ActiveSupport::Cache::MemoryStore.new
    @session_ttl = 3600 # 1 hour

    @sql_sanitizer = McpToolkit::SqlSanitizer.new

    @protocol_version = nil
    @supported_protocol_versions = McpToolkit::Protocol::SUPPORTED_VERSIONS
    @parent_controller = "ActionController::Base"
    @account_meta_key = "mcp-toolkit/account-id"
    @account_id_header = "X-MCP-Account-ID"

    initialize_authority_hook_defaults
    @generic_tool_name_prefix = ""

    @upstream_timeout = 10
    @upstream_list_ttl = 900 # 15 minutes
    @logger = nil

    @registry = McpToolkit::Registry.new
    @upstreams = McpToolkit::Gateway::UpstreamRegistry.new
  end

  # The authority transport's injection points all default to nil (a no-op): a
  # pure satellite/gateway never touches them. `rate_limit_window` is the sole
  # non-nil default (the window size only matters once a cap opts in).
  def initialize_authority_hook_defaults
    @rate_limiter = nil
    @usage_recorder = nil
    @usage_flusher = nil
    @session_data_builder = nil
    @tool_provider = nil
    @rate_limit_max_requests = nil # nil = rate limiting disabled
    @rate_limit_window = 3600 # 1 hour
    @superuser_resolver = nil # nil = duck-type principal.superuser?
  end

  # Config sugar: register a gateway upstream. Delegates to `upstreams.register`,
  # so a blank url is ignored (an unconfigured upstream is simply absent). Pass
  # `public_tool_list: false` for an upstream whose tool list varies by caller
  # privilege, to opt it out of the shared list cache.
  #
  #   c.register_upstream(key: "notifications", url: ENV["NOTIFICATIONS_SERVER_URL"])
  def register_upstream(key:, url:, public_tool_list: true)
    upstreams.register(key:, url:, public_tool_list:)
  end

  # The gateway handshake client name, defaulting to the server identity when the
  # host hasn't split it. Read (not stored) so a `server_name` change before the
  # split is set still flows through.
  def gateway_client_name
    @gateway_client_name || server_name
  end

  # The gateway handshake client version, defaulting to the server version.
  def gateway_client_version
    @gateway_client_version || server_version
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
    raise McpToolkit::Errors::ConfigurationError, "central_app_url is not configured" if central_app_url.to_s.empty?

    "#{central_app_url.chomp("/")}#{introspect_path}"
  end
end
