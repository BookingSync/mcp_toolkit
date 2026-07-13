## [0.4.1] - 2026-07-13

Backward-compatibility and discoverability fixes for the authority-path generic
tools, driven by an adopting host's parity review against the API contract the
gem replaced.

### Added

- `resource_schema` surfaces a resource's custom filters (`Resource#filter`)
  under `resource_filters` — name, type and description — so a client can
  discover them. The `Resource#filter` docs always promised this; nothing
  delivered it, leaving custom filters functional but unadvertised.
- The `resources` tool returns `filterable` (whether the resource accepts any
  filter — allowlist or custom) and the resource's usage `note` alongside
  name/description, so caveats surface at browse time, before a client picks a
  resource.
- The `list` tool description documents the full filter grammar — bare
  equality, comma/array IN sets, the `"null"` token, `{ op:, value: }`
  conditions and AND-ed condition arrays — plus resource-specific top-level
  filters. Previously the operator payload shape was not documented anywhere a
  client could see at runtime.
- Bare equality filters accept an Array of scalars as an IN set
  (`filter: { status: ["a", "b"] }`). Previously the array was stringified and
  comma-split into fragments that silently matched nothing.
- A JSON null filter value filters for `IS NULL` (like the `"null"` string
  token). Previously it was silently ignored.

All of the above applies to the SATELLITE generic tools too: they share the
executors and schema builder, so their `resources` output gains
`filterable`/`note`, their `resource_schema` output gains `resource_filters`,
and their descriptions document the same filter grammar.

### Host-compatibility seams (full parity with a pre-gem API contract)

For a host migrating an EXISTING MCP endpoint onto the gem, whose clients hold
the pre-gem contract:

- `config.session_key_prefix` + `config.session_payload_dumper` /
  `session_payload_loader` — keep the pre-gem session cache namespace and wire
  format, so old and new application versions SHARE live sessions during a
  rolling deploy (no forced client re-initialization). The sliding-TTL bump
  re-writes the raw stored payload untouched.
- `config.bare_filter_value_semantics = :literal` — bare filter values reach
  the WHERE clause verbatim (`"a,b"` is one literal string, `"null"` is the
  literal string, `""` matches empty-string rows, an Array — including nil
  elements — gets the adapter's native IN / OR-IS-NULL handling). The default
  `:tokenized` keeps the gem's comma/IN/`"null"`-token grammar. Operator
  conditions are identical in both modes.
- `config.non_numeric_pk_order = :primary_key` — lists of non-numeric-PK
  resources order by the primary key alone, preserving a pre-gem
  ORDER BY id contract. The default `:created_at` keeps chronological pages
  with the PK tiebreaker.
- `Resource#filter_requirements` — declares companion-key requirements (e.g. a
  polymorphic foreign key that is type-ambiguous without its `*_type`): the
  list executor rejects the key without its companion ("filter attribute X
  requires Y to also be provided") and `resource_schema` advertises the
  requirement, restoring safe polymorphic-FK filtering instead of dropping the
  key from the allowlist. Accepts a Hash or a lazily-resolved callable, like
  `filterable`.
- `resource_schema` output restores the remaining pre-gem keys: top-level
  `sparse_fieldsets: true` and `filter_examples` (ready-to-use payloads built
  from the resource's own attributes/relationships), `relationships[].resource`
  (nullable; `target_resource` remains as the resolved alias) and
  `relationships[].filter` (`keys` / `type` / `operators` / `requires`).
  Top-level nil keys are compacted (a nil `note` is omitted again).
- Operator conditions work on ANY column type: types outside the operator
  table (uuid, enum, jsonb, ...) accept `eq` / `in` instead of failing with
  "cannot be filtered with operators", and `date` columns accept `in` again.
- The `list` tools' input schemas declare `additionalProperties: true`
  explicitly (resource-specific filters arrive as top-level arguments).
- The authority `list` tool's served description states the bare-value grammar
  the host ACTUALLY configured: under `:literal` semantics the comma/`"null"`
  tokenization bullet is replaced by the literal-matching one, so served docs
  never advertise filters that would silently match nothing.
- The authority tools are advertised in alphabetical base-name order
  (`get`, `list`, `resource_schema`, `resources`) and string/text operator
  lists keep the pre-gem order (`eq, in, not_eq, matches, does_not_match`) —
  JSON arrays are ordered, so byte-diffing clients see no reorder.
- `get` / `resource_schema` / `resources` reject arguments outside their input
  schema with InvalidParams instead of silently ignoring them (pre-gem parity;
  `account_id` is always tolerated — the transport consumes it). `list` keeps
  accepting extra top-level arguments: they are the resource-specific filters.
- A companion key whose value the executor would SKIP (an empty string under
  `:tokenized` semantics) no longer satisfies a `filter_requirements` pairing —
  the foreign key is rejected rather than applied alone (type-ambiguous).
- `resource_filters` entries keep nil `type`/`description` keys (pre-gem
  shape) instead of compacting them; the relationship `filter_examples`
  companion sample value is `"User"` (pre-gem sample) rather than `"..."`.

### Known operator-path delta (documented, not reverted)

- `{ op: "in", value: "a,b" }` now splits the comma-separated string into an
  IN set (previously `in` matched the literal string `'a,b'` as a single
  element; only `eq` split). The split is what the operator means; revert by
  passing an Array with a single element if the literal is intended.

### Fixed

- Generic tool descriptions and input schemas rewrite sibling-tool references
  (e.g. "use the `resources` tool") to carry `config.generic_tool_name_prefix`,
  so a host that namespaces its generic tools no longer serves prose pointing
  at unprefixed tool names that do not exist on its server. The gateway
  aggregator applies the same rewrite with the upstream namespace, so a proxied
  `<app>__list` no longer points a client at the upstream's bare tool names
  (`McpToolkit::ToolReferenceRewriter`).
- `eq` / `in` operator conditions against `"null"` / null render `IS NULL`
  instead of `IN (NULL)`, which matches no rows in SQL.
- `eq` / `in` operator conditions accept an Array `value` (previously
  stringified and comma-split into fragments).
- Non-numeric-PK resources order by `created_at` WITH the primary key as a
  tiebreaker, restoring a total order so offset pagination cannot duplicate or
  skip rows that share a timestamp (e.g. bulk inserts).
- An Array mixing `{ op:, value: }` conditions with bare values is rejected
  with InvalidParams instead of being misread as bare equality values.
- One resource's failing lazy `filterable` resolution (e.g. a transient DB
  error inside a host-supplied callable) no longer fails the whole `resources`
  discovery index: the `filterable` key is omitted for that resource and the
  unresolved source is retried on the next read instead of permanently and
  silently resolving the allowlist to `{}`.

### Changed (explicit over silent — each previously returned a wrong or empty result)

- IN-set elements must be non-null scalars: a nil, Hash or nested-Array element
  inside an Array filter value raises InvalidParams (previously a Hash element
  raised a TypeError at query time and a nil element rendered the
  never-matching `IN (..., NULL)`). The `"null"` token is NOT resolved inside a
  set — SQL `IN` cannot match NULL — so a null-or-nothing condition is
  expressed as the filter's single scalar value.
- A null value with an operator other than `eq` / `in` / `not_eq` (comparisons,
  `matches` / `does_not_match`) raises InvalidParams; a comparison or LIKE
  against NULL can never match a row (previously `matches` with a JSON null
  matched every row via `LIKE '%%'`, and comparisons silently matched nothing).
- An op-less Hash as a bare filter value raises InvalidParams (previously it
  reached the database as a malformed condition).
- `{ op: "eq", value: "" }` matches rows whose value IS the empty string
  (previously it matched nothing via an empty IN set). A bare `""` filter value
  still means "no filter".

## [0.4.0] - 2026-07-06

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
- **Registry-backed authority tools** — the authority-path counterpart to the
  satellite's SDK tools, so a first-party server can serve the SAME four generic
  read tools (`resources` / `resource_schema` / `get` / `list`) over
  `config.registry` through the hand-rolled dispatcher, reusing the existing
  `ListExecutor` / `GetExecutor` / `ResourceSchema` / `Serialization` /
  `FieldSelection` / `Filtering` UNCHANGED.
  - `McpToolkit::Authority::RegistryToolProvider.new(config:)` — a `tool_provider`
    serving the four generic tools; `find(name)` returns a tool instance, and each
    tool declares NO static scope (the per-resource scope is enforced dynamically
    at call time). The satellite SDK tool path (`McpToolkit::Tools::*`,
    `McpToolkit::Server`) is untouched — this is added alongside it.
  - `McpToolkit::Authority::Tools::{Resources,ResourceSchema,Get,List}` — the four
    thin tools. Each resolves the `resource` argument against the registry
    (InvalidParams for unknown), gates a `superusers_only?` resource against
    `context.superuser?` (REFUSE in get/list/resource_schema, HIDE in resources),
    gates the resource's `required_scope_for` against the principal, and (get/list)
    requires a resolved `context.account`. Returns a raw Hash for the dispatcher to
    wrap — distinct by design from the satellite tools' `MCP::Tool::Response`.
  - `McpToolkit::Authority::CompositeToolProvider.new(*providers)` — composes
    several providers (e.g. the RegistryToolProvider + a host's bespoke tools)
    behind one `config.tool_provider`: `tool_definitions` concatenates in order,
    `find` returns the first match.
  - `config.generic_tool_name_prefix` (default `""`) — namespaces the four generic
    Registry-backed tools. When set (e.g. `"foo_"`) the provider advertises and
    resolves them as `foo_resources` / `foo_resource_schema` / `foo_get` /
    `foo_list`, letting a host keep stable, namespaced tool names for existing
    clients; the empty default keeps the bare base names.
- **`McpToolkit::Resource` generic seams** (all api-agnostic) — `superusers_only!`
  / `superusers_only?` (authority tools honor it), `note(text)` + reader (surfaced
  by `resource_schema`), and `filter(name, type:, description:, &applier)` +
  `custom_filters` — a resource-specific filter whose block narrows the scoped
  relation from a TOP-LEVEL request param, so a host can express a relational
  filter the generic equality/operator allowlist can't. `ListExecutor` applies the
  matching custom filters BEFORE the allowlist filters (its only change).
- **`McpToolkit::ResourceSchema` enrichment** — each attribute now advertises the
  filter `operators` it accepts (derived from `Filtering::OPERATORS_BY_TYPE`), and
  the resource `note` is passed through, so a client can discover exactly which
  `{ op:, value: }` conditions `list` will accept.
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
- **Built-in rate limiting** — `McpToolkit::RateLimiter`, a fixed-window
  per-principal counter backed by `config.cache_store`, plus
  `config.rate_limit_max_requests` (Integer, default `nil` = OFF) and
  `config.rate_limit_window` (seconds, default `3600`). When a cap is set, the
  authority transport's `mcp_rate_limit!` counts each request, sets the
  `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset` headers on
  every capped response, and over the limit renders a JSON-RPC error (code
  `-32029`) at HTTP `429` with a `Retry-After` header. Two new overridable hooks —
  `mcp_rate_limit_max_requests` (default `config.rate_limit_max_requests`) and
  `mcp_rate_limit_key` (default `mcp_principal.id`) — let a host keep the cap in
  its own constant/model or bucket the counter differently. `config.rate_limiter`
  remains as an escape hatch that fully replaces the built-in when set. A pure
  host that sets no cap is unaffected.
- **`config.superuser_resolver`** — an optional `->(principal) -> Boolean` making
  superuser a first-class, OPTIONAL gem concept. `Authority::Context#superuser?`
  calls it when set, else falls back to duck-typing `principal.superuser?` (false
  when the principal doesn't respond to it). Together with the existing
  `superusers_only!` resource flag and the authority tools' gating, this
  formalizes superuser gating; the default (no resolver, no superuser-aware
  principal) is "no superusers".
- **Lazy `parent_controller` (Constraint B)** — the engine's `ServerController` /
  `TokensController` and the authority `ServerController` are no longer eager-
  loadable files; they are built from the CURRENT config by
  `McpToolkit.build_engine_controllers!`, triggered lazily via `const_missing` and
  reset on each reload by the engine's `config.to_prepare`. The parent is therefore
  read only at build time — after the host's initializers/to_prepare — so a host's
  whole MCP initializer can live in `to_prepare`. `TokensController#introspect`
  behavior is preserved exactly.

### Fixed

- **Authority boundary returns JSON-RPC errors for bad input, not a 500** — a
  malformed JSON body now maps to a JSON-RPC parse error (`-32700`) via a
  `respond_to?`-guarded `rescue_from` (fires even from the session before_action),
  and a non-object request or batch element maps to `invalid_request` instead of
  raising a `NoMethodError` in the per-call loop.
- **`initialize` advertises `instructions`** — the authority dispatcher now
  includes `config.server_instructions` in the `initialize` result when set
  (omitted when nil), matching the SDK-backed satellite server and the documented
  contract.
- **Gateway tool-list cache is contract-enforced, not assumption-based** — the
  per-upstream list cache is keyed by upstream only, which is safe only when every
  upstream's `tools/list` is caller-independent. That is now an explicit
  registration contract: an upstream that filters its list by caller privilege
  registers `public_tool_list: false` and is pulled live per request (never
  cached), so a privileged caller's list can't leak to an unprivileged one.

### Removed

- The engine's `app/controllers/mcp_toolkit/{server_controller,tokens_controller}.rb`
  files, replaced by the lazy builder above (their routes + behavior are unchanged).

- **Gateway / upstream layer** (`McpToolkit::Gateway::*`) — the generic,
  SDK-independent machinery a central app uses to aggregate *other* MCP servers
  and proxy calls to them, previously an app-only concern. All app-specific values
  (upstream URLs, account-selector meta key, logger, timeouts) are injected via
  `McpToolkit::Configuration`; nothing in the layer names a deployment.
  - `McpToolkit::Gateway::UpstreamRegistry` — a PER-CONFIG registry of upstream
    servers (`Upstream = Data.define(:key, :url, :public_tool_list)` with
    `#name_for`), exposed as `config.upstreams` and reset with a fresh config (test
    isolation for free). API: `#register(key:, url:, public_tool_list: true)` (blank
    url ignored), `#reset!`, `#all`, `#find`, `#split_tool_name`. Config sugar:
    `config.register_upstream(key:, url:, public_tool_list: true)`.
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
  `parent_controller` (like `ServerController`). The route is drawn ONLY when
  `auth_role` is `:authority`: introspection is the provider side of the protocol,
  so a satellite (the default role) that mounts the engine gets no such route
  rather than one it should never answer. The controller also fails safe as defence
  in depth — with no `token_authenticator` it answers `{ valid: false }`.
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
