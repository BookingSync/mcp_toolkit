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
