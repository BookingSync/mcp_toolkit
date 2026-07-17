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

  # --- auth: OAuth authorization bridge (authority-only) ---------------------
  #
  # An OAuth 2.1 authorization-code + PKCE envelope around the tokens the host
  # ALREADY issues, for hosted MCP clients that will only authenticate by
  # discovering an authorization server and running a browser flow (and that
  # cannot be handed a token in the request URI, which the MCP authorization spec
  # forbids). It authenticates nobody: its authorization page asks the operator
  # to paste an existing access token and hands that same token back. See
  # McpToolkit::Oauth::ControllerMethods.

  # The exact redirect URIs an authorization code may be handed to — the
  # allowlist a REMOTE client's `redirect_uri` is matched against by exact
  # string. This is the bridge's load-bearing control: without it the authorize
  # endpoint would be an open redirect that emits authorization codes.
  #
  # Why it cannot just be opened up to "any client": the page is served from the
  # host's OWN origin under its own certificate and asks for a live token, so an
  # unvetted `redirect_uri` makes it a credential-phishing page hosted by the host
  # itself — an attacker sends the operator an authorize link carrying the
  # attacker's `code_challenge`, the operator pastes, and the code goes to the
  # attacker, who redeems it with the verifier they chose. PKCE cannot help; they
  # own the verifier. A real authorization server blocks this with a consent
  # screen naming the client plus an authenticated session. This bridge mocks both
  # away, and this allowlist is what compensates.
  #
  # EMPTY BY DEFAULT. Empty, and with `oauth_allow_native_client_redirects` off,
  # the bridge is DISABLED entirely (see `oauth_bridge?`) — so it cannot be
  # switched on without naming who may receive a code, and a host that wants
  # nothing to do with it sets nothing.
  #
  #   c.oauth_allowed_redirect_uris = ["https://client.example/callback"]
  #
  # @return [Array<String>]
  attr_accessor :oauth_allowed_redirect_uris

  # Permits NATIVE-client targets generically, without naming each one: loopback
  # on any port (RFC 8252 §7.3 — the port is ephemeral, so it could not be named
  # ahead of time) and private-use schemes (§7.1), i.e. `http://127.0.0.1:54321/cb`,
  # `http://localhost:*/cb`, `cursor://…`.
  #
  # Safe to open generically for the same reason the allowlist above cannot be:
  # these deliver the code to the OPERATOR'S OWN DEVICE, and the phishing above
  # needs it to reach a REMOTE attacker. (The residual risk is a malicious app
  # already installed on that machine squatting the scheme — local code execution,
  # a lost game regardless. RFC 8252 lets native apps skip pre-registration on
  # this same reasoning.) A remote `https://` callback is never covered by this,
  # whatever it is set to.
  #
  # OFF BY DEFAULT: switching it on says "any MCP client on my operators' machines
  # may receive a code", which is a decision, not a default — and so is an opt-in
  # signal in its own right.
  #
  #   c.oauth_allow_native_client_redirects = true
  #
  # @return [Boolean]
  attr_accessor :oauth_allow_native_client_redirects

  # The path McpToolkit::Engine is mounted at, used to build the `resource`
  # identifier, the issuer, the two metadata locations, and the bridge's own
  # endpoint URLs (their origin comes from the live request, so every host name
  # the app answers on works). MUST match the actual mount point, and the
  # `resource` it yields MUST equal the MCP endpoint URL as an operator types it
  # into their client.
  #
  # This path is ALSO what keeps the bridge out of the origin's global namespace
  # — see `oauth_protected_resource_path`.
  #
  # @return [String]
  attr_accessor :oauth_resource_path

  # Seconds an issued authorization code stays redeemable. Codes are single-use
  # (read-and-deleted at exchange); this only bounds a code that is never
  # redeemed. Short by design — a client exchanges immediately.
  #
  # @return [Integer]
  attr_accessor :oauth_authorization_code_ttl

  # The parent class of the bridge's controller, SEPARATE from
  # `parent_controller` and defaulting to ActionController::Base.
  #
  # They are separate because the two controllers have opposite needs. The MCP
  # transport is a JSON-only endpoint, so a host quite reasonably points
  # `parent_controller` at `ActionController::API` — which cannot render an HTML
  # view. The bridge's authorization page IS an HTML view. Deriving it from
  # `parent_controller` would therefore force a host to weaken its transport's
  # superclass just to switch the bridge on; keeping them apart means enabling
  # the bridge changes nothing about the transport.
  #
  # Point this at your own `ApplicationController` to inherit app branding (the
  # page renders with `layout: false` regardless, so an app layout that needs
  # asset-pipeline context is not pulled in).
  #
  # @return [String]
  attr_accessor :oauth_parent_controller

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

  # NOTE: (all data-path settings below): the list/get executors and the schema
  # builder read the PROCESS-GLOBAL `McpToolkit.config` — a per-instance config
  # bound to a provider affects tool prose only. Configure these globally.
  #
  # How a BARE (non-operator) filter value is interpreted by the list executor:
  #
  #   :tokenized (default) — a comma-separated string becomes an IN set, the
  #     "null" token (and a JSON null) matches NULL rows, an Array of non-null
  #     scalars is an IN set (nil/Hash/nested-Array elements rejected), and an
  #     empty string means "no filter".
  #   :literal — the value is handed to the WHERE clause verbatim (an op-less
  #     Hash is still rejected). This preserves an EXISTING API contract for a
  #     host whose pre-gem endpoint matched bare values literally: "a,b" is one
  #     literal string, "null" is the literal string, "" matches empty-string
  #     rows, an Array (including nil elements) gets the adapter's native IN /
  #     OR-IS-NULL handling.
  #
  # Operator conditions ({ op:, value: }) behave identically in both modes.
  #
  # @return [Symbol] :tokenized or :literal
  attr_accessor :bare_filter_value_semantics

  # Default ordering for a resource whose primary key is NON-numeric (numeric
  # PKs always order by :id):
  #
  #   :created_at (default) — ORDER BY created_at, <pk> (chronological pages
  #     with a total-order tiebreaker).
  #   :primary_key — ORDER BY <pk> only. Preserves an EXISTING API contract for
  #     a host whose pre-gem endpoint ordered every list by id.
  #
  # @return [Symbol] :created_at or :primary_key
  attr_accessor :non_numeric_pk_order

  # Per-column-type overrides for the operator sets advertised by
  # `resource_schema` and enforced by the list executor, merged over
  # McpToolkit::Filtering::OPERATORS_BY_TYPE. Lets a host preserve an EXISTING
  # operator contract exactly — both the schema bytes and which conditions are
  # accepted — e.g. `{ text: %w[eq in], date: %w[eq in] }` for a pre-gem
  # endpoint that never offered comparisons on those types. Empty by default
  # (the gem's own sets apply).
  #
  # @return [Hash{Symbol => Array<String>}]
  attr_reader :filter_operator_overrides

  # Assigns per-type operator overrides, rejecting any operator the gem cannot
  # safely dispatch. Only McpToolkit::Filtering::AREL_PREDICATIONS map onto an
  # Arel predication that binds/quotes its value; anything else (e.g. "extract")
  # would be public_send to an Arel attribute with the request value passed
  # through VERBATIM — an SQL-injection surface. Fail fast at config time so a
  # typo can never open that door at request time.
  def filter_operator_overrides=(overrides)
    overrides ||= {}
    unless overrides.is_a?(Hash)
      raise ArgumentError,
            "filter_operator_overrides must be a Hash of { column_type => [operator, ...] }, " \
            "got #{overrides.class}"
    end

    overrides.each do |type, operators|
      unsupported = Array(operators).map(&:to_s) - McpToolkit::Filtering::AREL_PREDICATIONS
      next if unsupported.empty?

      raise ArgumentError,
            "filter_operator_overrides[#{type.inspect}] has unsupported operator(s): " \
            "#{unsupported.join(", ")}. Allowed: #{McpToolkit::Filtering::AREL_PREDICATIONS.join(", ")}."
    end

    @filter_operator_overrides = overrides
  end

  # Caps how many values an IN-set filter may resolve to, and how many operator
  # conditions may be ANDed on a single attribute, so a valid token can't emit
  # an unbounded IN clause / AND-chain (oversized SQL + Arel AST and expensive
  # planning; rate limiting is opt-in via rate_limit_max_requests). Applies to
  # the default :tokenized bare-value semantics and to { op:, value: }
  # conditions. nil disables the cap.
  #
  # @return [Integer, nil]
  attr_accessor :max_filter_values

  # Caps how many JSON-RPC calls a single POST batch may carry on the authority
  # transport. Rate limiting is per-HTTP-request, so an uncapped batch would let
  # one request fan out unbounded work (N tool executions / N upstream calls)
  # under a single rate-limit tick. nil disables the cap.
  #
  # @return [Integer, nil]
  attr_accessor :max_batch_size

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
  # McpToolkit::Tools::AuthorityBase for a base that satisfies this.
  #
  # UNSET (the default), the provider is composed automatically: the generic
  # RegistryToolProvider (bound to this config) first, then every entry of
  # `extra_tool_providers` — so a host that only serves the generic tools plus
  # its own bespoke ones needs no provider plumbing at all. Assign explicitly to
  # take full control of the catalog.
  #
  # @return [#tool_definitions, #find]
  attr_writer :tool_provider

  def tool_provider
    @tool_provider || composed_tool_provider
  end

  # Additional tool providers (or bare TOOL classes, auto-wrapped in a
  # SingleToolProvider) composed AFTER the generic Registry-backed tools when
  # `tool_provider` is not explicitly assigned. The registry provider is always
  # first, so a generic tool name resolves to it; extras only answer their own
  # names.
  #
  #   config.extra_tool_providers = [MyApp::Tools::AuditLog]
  #
  # @return [Array<#tool_definitions, Class>]
  attr_accessor :extra_tool_providers

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

    initialize_oauth_bridge_defaults

    @cache_store = ActiveSupport::Cache::MemoryStore.new
    initialize_data_path_defaults

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

  # OAuth bridge defaults. The empty redirect allowlist AND the off native-client
  # switch are jointly what keep the bridge OFF (`oauth_bridge?`), so a host that
  # never configures it is unaffected.
  def initialize_oauth_bridge_defaults
    @oauth_allowed_redirect_uris = []
    @oauth_allow_native_client_redirects = false
    @oauth_resource_path = "/mcp"
    @oauth_authorization_code_ttl = 60
    @oauth_parent_controller = "ActionController::Base"
  end

  # Session-TTL and list-executor defaults: the :tokenized / :created_at
  # data-path semantics (a host preserving a pre-gem contract overrides these —
  # see each accessor's docs).
  def initialize_data_path_defaults
    @session_ttl = 3600 # 1 hour

    @sql_sanitizer = McpToolkit::SqlSanitizer.new
    @bare_filter_value_semantics = :tokenized
    @non_numeric_pk_order = :created_at
    @filter_operator_overrides = {}
    @max_filter_values = 500
    @max_batch_size = 50
  end

  # The default authority tool catalog when no explicit `tool_provider` is
  # assigned: the generic Registry-backed tools first (so a generic name always
  # resolves to them; included only when the host registered resources — a pure
  # gateway keeps contributing nothing), then each extra provider — a bare tool
  # CLASS is wrapped in a SingleToolProvider. Built per read (cheap, stateless
  # providers), so a reload that re-assigns `extra_tool_providers` or registers
  # resources takes effect immediately.
  def composed_tool_provider
    providers = []
    providers << McpToolkit::Authority::RegistryToolProvider.new(config: self) if registry.resources.any?
    Array(extra_tool_providers).each do |provider|
      providers << (provider.respond_to?(:tool_definitions) ? provider : McpToolkit::Authority::SingleToolProvider.new(provider))
    end
    return nil if providers.empty?
    return providers.first if providers.one?

    McpToolkit::Authority::CompositeToolProvider.new(*providers)
  end
  private :composed_tool_provider

  # The authority transport's injection points all default to nil (a no-op): a
  # pure satellite/gateway never touches them. `rate_limit_window` is the sole
  # non-nil default (the window size only matters once a cap opts in).
  def initialize_authority_hook_defaults
    @rate_limiter = nil
    @usage_recorder = nil
    @usage_flusher = nil
    @session_data_builder = nil
    @tool_provider = nil
    @extra_tool_providers = []
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

  # Declares the gateway's upstreams from an ENV-var map — `{ key => env var
  # name }` — the shape every authority host repeats: resets the registry first
  # (idempotent across code reloads, where the registration typically re-runs in
  # a `to_prepare`), and an upstream whose ENV url is blank is never registered,
  # so an unconfigured environment behaves like no-upstreams. `env` is
  # injectable for tests.
  #
  #   config.register_upstreams_from_env("billing" => "BILLING_MCP_URL")
  def register_upstreams_from_env(mapping, env: ENV)
    upstreams.reset!
    mapping.each { |key, env_var| register_upstream(key:, url: env[env_var.to_s]) }
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

  # The well-known prefixes the two metadata documents hang off. The resource
  # path is INSERTED after these, never appended to the origin — see
  # `oauth_protected_resource_path`.
  PROTECTED_RESOURCE_WELL_KNOWN = "/.well-known/oauth-protected-resource"
  AUTHORIZATION_SERVER_WELL_KNOWN = "/.well-known/oauth-authorization-server"

  # `oauth_resource_path` normalized for URL building: no trailing slash, and
  # empty when the MCP endpoint IS the origin root (where there is no path
  # component to insert).
  #
  # @return [String] e.g. "/mcp", or "" for a root-mounted endpoint.
  def oauth_resource_path_component
    path = oauth_resource_path.to_s.chomp("/")
    path == "/" ? "" : path
  end

  # Where the protected-resource metadata (RFC 9728) answers, and where
  # `WWW-Authenticate` points.
  #
  # Path-SCOPED (`/.well-known/oauth-protected-resource/mcp`), never the bare
  # path, because the bare ones are ORIGIN-GLOBAL: they describe the authorization
  # server of the whole origin, which on a host already running an unrelated OAuth
  # provider is that provider's claim to make, not an MCP server's. RFC 8414 §3.1
  # exists for this — "Using path components enables supporting multiple issuers
  # per host" — and MCP's 2025-11-25 authorization spec gives a path-ful issuer no
  # root fallback, so scoping is the correct reading rather than a workaround.
  #
  # A root-mounted endpoint has no path to insert and gets the bare paths, which is
  # correct there: it really is that origin's only authorization server.
  #
  # @return [String]
  def oauth_protected_resource_path
    "#{PROTECTED_RESOURCE_WELL_KNOWN}#{oauth_resource_path_component}"
  end

  # Where the authorization-server metadata (RFC 8414) answers. Path-inserted for
  # the same reason, and it MUST agree with the issuer: a client constructs this
  # URL from the issuer it was given.
  #
  # @return [String]
  def oauth_authorization_server_path
    "#{AUTHORIZATION_SERVER_WELL_KNOWN}#{oauth_resource_path_component}"
  end

  # Whether the OAuth authorization bridge is live: its routes are drawn, and the
  # authority transport advertises it on a 401 via `WWW-Authenticate`.
  #
  # Gated on three conditions, each for its own reason.
  #
  # AUTHORITY-ONLY, because the flow hands back a token this app itself
  # authenticates — a satellite's tokens belong to its central app, so there is
  # nothing here for it to authorize against.
  #
  # A `token_authenticator` must be set, because the bridge cannot function
  # without one: it verifies the pasted token through it on both legs. Gated
  # rather than left to fail at request time so a misconfigured host serves no
  # bridge at all, instead of an authorization page that accepts an operator's
  # token and then errors — the sibling introspection endpoint fails safe the
  # same way.
  #
  # And at least one redirect target must be named — an allowlist entry, or the
  # native-client switch — so the bridge cannot be running without a bound
  # answer to "who may receive a code". Both are empty/off by default, which is
  # what makes an unconfigured host byte-identical to one without the bridge.
  #
  # @return [Boolean]
  def oauth_bridge?
    return false unless authority?
    return false if token_authenticator.nil?

    Array(oauth_allowed_redirect_uris).any? || !!oauth_allow_native_client_redirects
  end

  # Full introspection URL the satellite POSTs to. Raises a clear error if the
  # central URL was never configured.
  def introspect_url
    raise McpToolkit::Errors::ConfigurationError, "central_app_url is not configured" if central_app_url.to_s.empty?

    "#{central_app_url.chomp("/")}#{introspect_path}"
  end
end
