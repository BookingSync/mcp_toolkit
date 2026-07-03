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

- The gateway / upstream-aggregation layer (`Mcp::Upstreams*`) is intentionally
  out of scope (core-only).
