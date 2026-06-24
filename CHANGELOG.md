## [Unreleased]

### Added

- OAuth-style **scope** enforcement. Tokens now carry `scopes` of the form
  `<app>__<action>` (e.g. `notifications__read`). Every tool call requires the exact
  `"#{required_application}__#{scope_action}"` scope; a token lacking it is rejected
  with an `isError` result. NULL/empty token scopes remain unrestricted
  (backward-compat).
- `scope_action` class-level DSL on `Tools::Base` (defaults to `:read`, inherited
  by subclasses). A write tool declares `scope_action :write`. The generic tools
  (`list`, `get`, `resources`, `resource_schema`) are all reads.
- `Auth::Introspection::Result#authorized_for_scope?(required_scope)` — exact-scope
  check; `#authorized_for_application?` now derives app-reach from `scopes` instead
  of `applications`.
- New `scopes` field in the introspection contract: parsed by the satellite
  (`Auth::Introspection`) and emitted by the authority (`Auth::Authority#introspection_payload`,
  reading `token.scopes` when present, else `[]`).

### Changed

- Authorization now derives from `scopes`, not `applications`. The `applications`
  field is retained in the payload for backward-compat but is no longer used for
  auth.

## [0.1.0] - 2026-06-18

Initial extraction from two independently-grown internal MCP servers.
Standardizes on the official `mcp` gem (`~> 0.18`) as the wrapped JSON-RPC core.

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
  `serialize_collection` contract so API-v3 / Prometheus-derived serializers slot
  in unchanged.
- Dual-role authentication: satellite (`Auth::Introspection` +
  `Auth::Authenticator`, with short-TTL caching + required-application check) and
  authority (`Auth::Authority` — local token authentication + introspection
  payload responder). All config-driven.
- `McpToolkit::Session` — cache-backed, sliding-TTL `Mcp-Session-Id` sessions.
- `McpToolkit::Transport::ControllerMethods` — an includable Streamable-HTTP
  controller concern (POST/GET/DELETE/health, SSE-on-`Accept`, 202-for-notifications).

### Notes

- The gateway / upstream-aggregation layer (`Mcp::Upstreams*`) is intentionally
  out of scope (core-only).
