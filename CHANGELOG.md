## [0.1.0]

Initial extraction from two independently-grown internal MCP servers.
Standardizes on the official `mcp` gem (`~> 0.18`) as the wrapped JSON-RPC core.
This remains the accumulation point until the first release is cut.

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
- OAuth-style **scope** enforcement. Tokens carry `scopes` of the form
  `<app>__<action>` (e.g. `notifications__read`). Every tool call requires the
  exact `"#{required_application}__#{scope_action}"` scope; a token lacking it is
  rejected with an `isError` result. A tool is allowed iff every scope it
  requires is present in the token's scopes — so empty token scopes are
  unrestricted ONLY for tools that require no scope.
- `scope_action` class-level DSL on `Tools::Base` (defaults to `:read`, inherited
  by subclasses). A write tool declares `scope_action :write`. The generic tools
  (`list`, `get`, `resources`, `resource_schema`) are all reads.
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
