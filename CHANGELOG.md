## [0.5.0] - 2026-07-06

### Added

- **Authority dispatch path** — a hand-rolled JSON-RPC front-end for a first-party
  server that authenticates tokens locally and serves its OWN tools (and, as a
  gateway, aggregates + proxies upstreams) WITHOUT the official `mcp` SDK in the
  request path. It coexists with the SDK-backed satellite path
  (`McpToolkit::Server.build`) by design — the gem now carries two dispatch
  front-ends, each for its role. The satellite path is unchanged.
  - `McpToolkit::Protocol` — JSON-RPC constants + envelope helpers
    (`SUPPORTED_VERSIONS`, `LATEST_VERSION`, `JSONRPC_VERSION`, `ErrorCodes`,
    `Error` + subclasses with `#code`/`#data`/`#to_h`, `success_response` /
    `error_response`). The byte contract of a first-party endpoint's error
    envelope + version negotiation.
  - `McpToolkit::Dispatcher` — `new(context:, config:)` + `#handle_request(request)`.
    Dispatches `initialize` / `initialized` / `tools/list` / `tools/call` / `ping`
    and the custom `notifications/<app>/tools/list_changed` cache-bust. `tools/list`
    merges the host's own tool definitions with the gateway's namespaced upstream
    tools; `tools/call` routes a namespaced name to `Gateway::Proxy` (translating
    `UnknownUpstream` → method-not-found and relaying an upstream JSON-RPC error
    verbatim) or a host tool (scope-gated) otherwise. Server identity + negotiated
    versions come from config; NO SDK touchpoint.
  - `McpToolkit::Authority::ControllerMethods` — the authority transport as an
    includable concern. Every billing/tenancy step is an overridable hook
    (`mcp_authenticate!`, `mcp_rate_limit!`, `mcp_track_usage`, `mcp_flush_usage`,
    `mcp_resolve_account`, `mcp_session_data`, `mcp_dispatch`, `mcp_health_payload`,
    `mcp_config`), each defaulting to a config callable so a PURE host needs no
    subclass. The per-request loop RE-RESOLVES the account for every JSON-RPC call
    — including each element of a batch — so a mixed-account batch still meters one
    usage event per call against the right account (the batch is never delegated to
    a bulk handler that couldn't re-resolve per element).
  - `McpToolkit::Authority::ServerController` — a base controller (concern wired in,
    lazily-parented) a host subclasses when its hooks touch app models (the
    recommended path).
  - `McpToolkit::Authority::Context` — the per-request context threaded into the
    dispatcher + tools: `account`, `principal`, `bearer_token`, and a derived
    `superuser?` (duck-typed off the principal).
  - `McpToolkit::Tools::AuthorityBase` — an optional base for a host's own tools
    (class DSL `tool_name` / `description` / `input_schema` /
    `required_permissions_scope` / `definition`; `.call(context:, **arguments)`
    entry; context accessors; `ensure_resource_accessible!`; ArgumentError →
    InvalidParams / StandardError → InternalError mapping). Host tools plug in
    through the api-agnostic `config.tool_provider` seam — the gem never references
    a host's API layer, serializers, or resource catalog.
- **`config.tool_provider`** — the api-agnostic tool seam. Duck-typed:
  `provider.tool_definitions(context) -> [{ name:, description:, inputSchema: }]`
  (context lets the host hide superuser-only tools) and `provider.find(name) -> a
  tool object` (responding to `#required_permissions_scope` + `#call(context:,
  **arguments)`). The dispatcher enforces the per-tool scope gate CENTRALLY.
- **Server-vs-gateway identity split** — `config.gateway_client_name` /
  `gateway_client_version` (each defaulting to `server_name` / `server_version`).
  `Gateway::Client`'s handshake `clientInfo` now reads the GATEWAY identity, so an
  authority can advertise its own `server_name` to its callers while keeping its
  upstream handshake byte-identical.
- **`config.supported_protocol_versions`** (default
  `McpToolkit::Protocol::SUPPORTED_VERSIONS`) — the version set the authority
  dispatcher negotiates.
- **`config.rate_limiter` / `usage_recorder` / `usage_flusher`** — the authority
  transport's billing hooks as config callables (all default `nil` / no-op).
- **Lazy `parent_controller` (Constraint B)** — the engine's `ServerController` /
  `TokensController` and the authority `ServerController` are no longer eager-
  loadable files; they are built from the CURRENT config by
  `McpToolkit.build_engine_controllers!`, triggered lazily via `const_missing` and
  reset on each reload by the engine's `config.to_prepare`. The parent is therefore
  read only at build time — after the host's initializers/to_prepare — so a host's
  whole MCP initializer can live in `to_prepare`. `TokensController#introspect`
  behavior is preserved exactly.

### Removed

- The engine's `app/controllers/mcp_toolkit/{server_controller,tokens_controller}.rb`
  files, replaced by the lazy builder above (their routes + behavior are unchanged).

## [0.4.0] - 2026-07-06

### Added

- **Gateway / upstream layer** (`McpToolkit::Gateway::*`) — the generic,
  SDK-independent machinery a central app uses to aggregate *other* MCP servers
  and proxy calls to them, previously an app-only concern. All app-specific values
  (upstream URLs, account-selector meta key, logger, timeouts) are injected via
  `McpToolkit::Configuration`; nothing in the layer names a deployment.
  - `McpToolkit::Gateway::UpstreamRegistry` — a PER-CONFIG registry of upstream
    servers (`Upstream = Data.define(:key, :url)` with `#name_for`), exposed as
    `config.upstreams` and reset with a fresh config (test isolation for free).
    API: `#register(key:, url:)` (blank url ignored), `#reset!`, `#all`, `#find`,
    `#split_tool_name`. Config sugar: `config.register_upstream(key:, url:)`.
  - `McpToolkit::Gateway::Client` — a minimal Streamable-HTTP MCP client
    (`#tools_list`, `#tools_call`) with single-shot session-loss recovery (HTTP
    404 / JSON-RPC `-32001`), SSE `data:` unwrapping, and content negotiation. Its
    `Client::Error` (< `McpToolkit::Error`) carries `jsonrpc_error` / `http_status`
    and references NO transport/protocol-error class — the consumer maps it. The
    handshake `clientInfo` and protocol version come from config
    (`DEFAULT_PROTOCOL_VERSION` falls back to the wrapped `mcp` SDK's latest).
  - `McpToolkit::Gateway::Aggregator` — namespaces + caches (`config.cache_store`,
    `config.upstream_list_ttl`) each upstream's tool list, pulled CONCURRENTLY via
    concurrent-ruby (wrapped in `Rails.application.executor` when a booted Rails app
    is present, plain futures otherwise). Only a non-empty pull is cached; a stale
    empty is a miss (poisoned-cache self-heal); a failing upstream degrades (omit +
    log) rather than breaking the list.
  - `McpToolkit::Gateway::Proxy` — proxies a namespaced call, forwarding the
    resolved `account_id` as `_meta[config.account_meta_key]`. An unknown key raises
    `McpToolkit::Gateway::UnknownUpstream`; an upstream failure raises
    `McpToolkit::Gateway::UpstreamCallError` (carrying `jsonrpc_error` /
    `http_status`). Neither is mapped to a protocol-error class here.
- **Authority introspection endpoint** — `McpToolkit::TokensController#introspect`,
  drawn by the engine at `POST /mcp/tokens/introspect`, so a central app answers
  introspection with no controller of its own. Its parent class is configurable via
  `parent_controller` (like `ServerController`). Safe to draw unconditionally: with
  no `token_authenticator` it answers `{ valid: false }`.
- **`McpToolkit::Session#data`** — an opaque payload attachable at
  `create!(data:)` and round-tripped through `find`, so an authority can bind a
  session to a token id (letting a revoked token kill an in-flight session). The
  gem does not interpret it; legacy rows default to `{}`.
- `McpToolkit::Configuration` gains `upstreams` (a `Gateway::UpstreamRegistry`),
  `register_upstream`, `upstream_timeout` (default `10`), `upstream_list_ttl`
  (default `900`), and `logger` (default `nil`; all gateway/session call sites
  guard with `logger&.`).
- `concurrent-ruby` is now a direct dependency (already transitive via
  activesupport) — the aggregator's parallel upstream pulls require it.

## [0.3.0] - 2026-07-03

### Added

- **Resource discovery DX** improvements, closing gaps hit when an MCP agent had to guess a
  related resource's name rather than discover it:
  - The `resource_schema` tool now names, for each relationship, the `target_resource` it
    resolves to (callable via `list` / `get`). A `scheduled_notifications.notification` link is
    thus discoverably the `notifications` resource instead of a name to guess. Additive and
    backward compatible: it is omitted when the target can't be resolved (e.g. a polymorphic
    link), so existing relationship consumers are unaffected.
  - An unknown resource name now raises a "did you mean" message — the closest registered
    name(s) via Ruby's stdlib `DidYouMean::SpellChecker` (with a dependency-free edit-distance
    fallback), plus the full list when the catalog is short. It flows unchanged to the caller as
    a clean `InvalidParams` tool error via the existing `resolve_descriptor` path.

### Changed

- The transport controller now logs a WARN when a POST arrives with no matching session
  (`mcp_render_session_not_found`): a greppable, id/token-free line recording only whether a
  session-id header was present, so a non-shared `cache_store` misconfiguration surfaces in a
  satellite's own logs instead of only as a client-side 404. The logger defaults to
  `Rails.logger` and is overridable via the new `mcp_logger` controller hook.

## [0.2.0] - 2026-07-02

### Added

- **Sparse fieldsets** (JSON:API `fields[type]`) on the `get` and `list` tools. Pass
  `fields` — an array of names or a comma-separated string — to return only the named
  attributes and/or relationships, shrinking the response (a token win for MCP clients).
  Attribute and relationship names share one flat namespace; `resource_schema` advertises
  the valid values. Unknown names are rejected with `InvalidParams` (consistent with
  unknown filter keys), so a typo is actionable rather than silently dropped.
  - `McpToolkit::Serializer::Base` honors the selection NATIVELY: `serialize_one` /
    `serialize_collection` / `serializable_hash` take an optional `fields:` keyword, and
    unselected `has_many` relationships are never loaded (a query win, not just a payload
    win). Under a selection the `links` block is omitted entirely when no relationship is
    selected.
  - `McpToolkit::FieldSelection` parses + validates the request; `McpToolkit::Serialization`
    bridges the executors to the serializer.
- **Backward compatible.** Omitting `fields` returns the full shape exactly as before. An
  injected serializer that does NOT declare a `fields:` keyword still supports sparse
  fieldsets — the toolkit prunes its output to the requested `fields` — so the serializer
  injection contract is unchanged.

## [0.1.0] - 2026-06-28

Initial extraction from two independently-grown internal MCP servers into a single
shared gem. Standardizes on the official `mcp` gem (`~> 0.18`) as the wrapped
JSON-RPC core. Per-tool scope is declared explicitly via `required_permissions_scope`,
and a mountable `McpToolkit::Engine` gives satellites their MCP routes without the
hand-rolled controller wiring.

### Added

- `McpToolkit.configure` / `config` / `registry` / `reset_config!` — a single
  injectable `Configuration` object (`MCPToolkit` alias provided).
- `McpToolkit::Server.build` — wraps `MCP::Server` (the official gem) with the
  generic toolset registered and the per-request `server_context`.
- Generic, registry-driven tools subclassing `MCP::Tool`: `resources`,
  `resource_schema`, `get`, `list`.
- `McpToolkit::Registry` + `Resource` DSL (`model` / `serializer` / `scope` /
  `description` / `filterable`) + `ListExecutor` / `GetExecutor` /
  `ResourceSchema`. The serializer is injectable per resource.
- `McpToolkit::Serializer::Base` — the default serializer DSL (`attributes`,
  `has_one`, `has_many`, `translates`), with a documented `serialize_one` /
  `serialize_collection` contract so an app's existing serializers slot in
  unchanged.
- Dual-role authentication: satellite (`Auth::Introspection` +
  `Auth::Authenticator`, with short-TTL caching) and authority (`Auth::Authority`
  — local token authentication + introspection payload responder). All
  config-driven. The introspection HTTP call is owned by
  `Auth::AuthorityServerClient`.
- OAuth-style **scope** enforcement, declared EXPLICITLY per resource. Tokens
  carry `scopes` of the form `<app>__<action>` (e.g. `notifications__read`). A
  resource declares the scope it requires via `required_permissions_scope`, or a
  satellite declares one default for all resources via
  `Registry#default_required_permissions_scope`. A resource's effective scope is
  its own declaration, else the registry default, else none. A tool is allowed
  iff the token carries the required scope; a resource (and default) with no
  declared scope is reachable by any valid token. Whether ANY scope is required
  is decided per tool — there is NO app-wide permission setting.
- `Resource#required_permissions_scope` / `#effective_required_permissions_scope`
  and `Registry#default_required_permissions_scope` / `#required_scope_for` — the
  explicit scope DSL + resolution. `reset!` preserves the registry default (it's
  declared in `configure`, not per-reload).
- `Tools::Base.with_account` / `.with_authentication` take an explicit
  `required_scope:` keyword (resolved by the caller from the resource); the `list`
  / `get` / `resource_schema` tools resolve the resource FIRST, then enforce its
  effective scope. The discovery tools (`resources`, `resource_schema`) require
  the registry default scope.
- A **mountable Rails engine**, `McpToolkit::Engine`, plus the gem-provided
  `McpToolkit::ServerController`: a satellite writes `mount McpToolkit::Engine =>
  "/mcp"` instead of four hand-declared routes + a controller. The controller's
  parent class is configurable via `Configuration#parent_controller` (default
  `"ActionController::Base"`; set `"ApplicationController"` for `helper_method`
  compat). The engine is ADDITIVE — `Transport::ControllerMethods` remains a
  standalone concern. Both the engine and the gem's `app/controllers` are loaded
  only when Rails is present; the gem's non-Rails consumers and unit suite never
  reference them. The four routes are drawn in the engine's `config/routes.rb`
  (NOT a class-body `routes.draw`), so they survive Rails' routes_reloader — a
  class-body draw is wiped on the first route reload, leaving the engine
  route-less and every `/mcp` 404'ing. A regression spec boots a real
  `Rails::Application` in an isolated subprocess and asserts the engine route set
  survives a `reload_routes!`.
- `Auth::Introspection::Result#authorized_for_scope?(required_scope)` — exact-scope
  check used by the tool layer.
- `scopes` field in the introspection contract: parsed by the satellite
  (`Auth::Introspection`) and emitted by the authority
  (`Auth::Authority#introspection_payload`).
- Injectable `Configuration#sql_sanitizer` (defaulting to the ActiveRecord-backed
  `McpToolkit::SqlSanitizer`) used to escape LIKE wildcards in `matches` /
  `does_not_match` filters, so a non-Rails host can supply its own.
- `McpToolkit::Session` — cache-backed, sliding-TTL `Mcp-Session-Id` sessions.
- `McpToolkit::Transport::ControllerMethods` — an includable Streamable-HTTP
  controller concern (POST/GET/DELETE/health, SSE-on-`Accept`, 202-for-notifications).
- `get` accepts a string/UUID record id as well as an integer one.

### Notes

- The gateway / upstream-aggregation layer was intentionally out of scope for this
  initial extraction. It was later extracted into the gem in 0.4.0 (see above), as
  `McpToolkit::Gateway::*` — fully config-injected and app-agnostic.
