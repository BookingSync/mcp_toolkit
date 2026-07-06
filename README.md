# mcp_toolkit

An opinionated toolkit for building **account-scoped, read-only MCP servers** on
top of the official [`mcp`](https://rubygems.org/gems/mcp) gem.

It extracts the shared MCP-server framework that several apps grew independently
into one versioned, standalone library, so a new app can add an MCP server in
~20 lines. It ships:

- a **Streamable-HTTP transport** (POST/GET/DELETE/health, SSE-on-`Accept`,
  `202`-for-notifications) as an includable controller concern;
- **cache-backed sessions** (`Mcp-Session-Id`, sliding TTL) that survive across
  Puma workers;
- **central-app token introspection** in two roles — be the **authority**
  (authenticate local tokens + answer introspection) or a **satellite**
  (validate forwarded tokens against the central app);
- a registry-driven **"generic tools over N resources"** dispatcher
  (`list` / `get` / `resources` / `resource_schema`) wrapping the official `mcp`
  gem's JSON-RPC core;
- an **injectable serializer DSL** (the default base, or your own — e.g. an
  existing app serializer).

The JSON-RPC protocol, version negotiation, and error envelopes are delegated to
the official `mcp` gem; this toolkit owns everything around it.

## Installation

```ruby
# Gemfile
gem "mcp_toolkit"
```

```bash
bundle install
```

## Concepts

A typical topology is **one central app** responsible for auth and **N
satellites** that expose their own resources and validate forwarded tokens by
introspecting against the central app. `mcp_toolkit` makes both roles trivial.

Everything is driven by a single config object:

```ruby
McpToolkit.configure do |c|
  # ...
end
```

(`MCPToolkit` is an alias — `MCPToolkit.configure { ... }` works identically.)

---

## Quickstart 1 — a satellite MCP server (~20 lines)

A satellite exposes read-only resources and trusts no token locally: it
introspects each forwarded bearer token against the central app.

**1. Configure** (`config/initializers/mcp_toolkit.rb`):

```ruby
McpToolkit.configure do |c|
  c.server_name          = "acme-mcp"
  c.server_instructions  = "Read-only access to this account's widgets domain."

  # --- satellite auth ---
  c.auth_role            = :satellite
  c.central_app_url      = ENV.fetch("MCP_CENTRAL_APP_URL") # POSTs <url>/mcp/tokens/introspect

  # The scope every tool requires, declared ONCE for all resources. A resource
  # can override it per-resource (see below). Omit entirely for "no scope
  # required". Whether a scope is required is PER TOOL — there is no app-wide
  # permission flag.
  c.registry.default_required_permissions_scope "widgets__read"

  # Map the central account id to this app's LOCAL scope root (an Account here).
  c.account_resolver = ->(synced_account_id) { Account.find_by(synced_id: synced_account_id) }

  # Share sessions/introspection across workers.
  c.cache_store = Rails.cache

  # The engine's controller inherits ActionController::Base by default; point it
  # at ApplicationController if your stack needs helper_method (e.g. logstasher).
  c.parent_controller = "ApplicationController"
end
```

**2. Register resources** (same initializer, wrapped in `to_prepare` so they
refresh on reload). Every `scope` block MUST return a relation already rooted on
the resolved scope root — this is the single tenancy chokepoint:

```ruby
Rails.application.config.to_prepare do
  McpToolkit.registry.reset!

  McpToolkit.registry.register(:widgets) do
    model       Widget
    serializer  WidgetSerializer                    # your serializer (see below)
    description "Widget templates + their scheduling rules."
    scope(&:widgets)                                # account.widgets
  end

  McpToolkit.registry.register(:scheduled_widgets) do
    model       ScheduledWidget
    serializer  ScheduledWidgetSerializer
    description "Scheduled widget deliveries."
    # Expose a public filter key that maps to a synced storage column:
    filterable  booking_id: :synced_booking_id
    # Override the registry default scope for just this resource (optional):
    required_permissions_scope "widgets__read"
    scope { |account| ScheduledWidget.where(synced_account_id: account.synced_id) }
  end
end
```

Each resource's effective required scope is its own `required_permissions_scope`
if declared, else the registry's `default_required_permissions_scope`, else none.

**3. Mount the transport** — one line. The gem ships the engine *and* the
controller, so a satellite writes no routes and no controller of its own:

```ruby
# config/routes.rb
mount McpToolkit::Engine => "/mcp"
```

That yields `POST/GET/DELETE /mcp` + `GET /mcp/health` exactly as a hand-rolled
satellite did. The four generic tools (`resources`, `resource_schema`, `get`,
`list`) are now live over Streamable-HTTP, each call authenticated by
introspecting the forwarded token and scoped to the resolved account.

> Prefer to keep your own controller? The transport is also a standalone concern
> — `include McpToolkit::Transport::ControllerMethods` in a controller and route
> the four endpoints yourself. The engine is purely additive.

---

## Quickstart 2 — make your app the auth authority

The authority authenticates plaintext tokens locally and answers the
introspection requests satellites send.

**1. Configure** the local token lookup (your `AccessToken.authenticate` equivalent):

```ruby
McpToolkit.configure do |c|
  c.auth_role          = :authority
  c.token_authenticator = ->(plaintext) { AccessToken.authenticate(plaintext) }
  c.cache_store        = Rails.cache
end
```

The token object your authenticator returns must respond to:
`kind` (`:accounts_user` | `:user`), `account_id`, `account_ids`, `expires_at`
(an `#iso8601`-able time or nil), and `scopes` (an array of `<app>__<action>`
scopes; `[]` = no scopes). Optionally `touch_last_used!`. A typical app token
model (e.g. `AccessToken`) fits.

**2. Expose the introspection endpoint** the satellites call:

```ruby
class TokensController < ActionController::API
  def introspect
    token = McpToolkit::Auth::Authority.authenticate(extract_token)
    return render(json: McpToolkit::Auth::Authority.invalid_payload, status: :unauthorized) unless token

    render json: McpToolkit::Auth::Authority.introspection_payload(token)
  end

  private

  def extract_token
    auth = request.headers["Authorization"]
    return auth.sub("Bearer ", "") if auth&.start_with?("Bearer ")

    request.headers["X-MCP-Token"].presence || params[:token].presence
  end
end
```

```ruby
# config/routes.rb
post "mcp/tokens/introspect", to: "tokens#introspect"
```

The payload `introspection_payload` emits is exactly the contract the satellite's
`McpToolkit::Auth::Introspection` parses — the two roles interoperate out of the
box. (An app can be **both**: a central app that also exposes its own tools just
sets the authority config and registers resources + the transport controller.)

---

## Serializer injection (e.g. an existing app serializer)

The registry takes a **serializer class per resource**. The gem ships a default
DSL base (`McpToolkit::Serializer::Base`), but the only thing the executors
require is that a serializer responds to two class methods:

```ruby
serializer.serialize_one(record, scope:)
  # => Hash (a single record's shape), or nil for a nil record

serializer.serialize_collection(records, scope:, total_count:, limit:, offset:)
  # => { <root_key> => [ <record_hash>, ... ], meta: { total_count:, limit:, offset: } }
```

Any class satisfying that contract slots in — including an app's existing
serializers. Register it directly:

> **Sparse fieldsets.** Both methods also accept an optional `fields:` keyword (an
> array of attribute/relationship names) so `get` / `list` can return a subset of
> a record's shape. Honoring it natively — the bundled base does — skips computing
> the unselected members; a serializer that ignores it still works, because the
> toolkit prunes its output to the requested `fields` instead. Omitting `fields:`
> (the default) returns the full shape, so this is fully backward-compatible.

```ruby
McpToolkit.registry.register(:bookings) do
  model       Booking
  serializer  BookingSerializer   # your existing serializer
  scope { |account| account.bookings }
end
```

### Using the bundled base

```ruby
class WidgetSerializer < McpToolkit::Serializer::Base
  attributes :id, :name, :active, :created_at, :updated_at
  translates :subject, :template_html         # Globalize-backed { locale => value }

  has_one  :account, foreign_key: :synced_account_id
  has_one  :layout
  has_many :scheduled_widgets
end
```

It emits declared attributes as symbol keys (in declaration order), a sorted
string-keyed `"links"` hash (ids / `{id:,type:}` for polymorphic / sorted arrays
for `has_many`), and `iso8601(6)` timestamps. To power the `resource_schema`
discovery tool, a custom serializer may also expose `declared_attributes` /
`declared_associations`; this is optional (the base provides them).

---

## Configuration reference

| Setting | Default | Purpose |
|---|---|---|
| `server_name` / `server_version` / `server_instructions` | `"mcp-server"` / `"1.0.0"` / `nil` | advertised on `initialize` |
| `gateway_client_name` / `gateway_client_version` | `server_name` / `server_version` | `clientInfo` a gateway presents to its upstreams (identity split) |
| `serializer_base` | `McpToolkit::Serializer::Base` | the default base to subclass |
| `auth_role` | `:satellite` | `:satellite` or `:authority` |
| `central_app_url` | `nil` | satellite: base URL of the auth authority |
| `introspect_path` | `"/mcp/tokens/introspect"` | satellite: appended to `central_app_url` |
| `introspection_cache_ttl` | `45` | seconds to cache introspection results |
| `introspection_timeout` | `10` | HTTP timeout (s) for the introspection call |
| `account_resolver` | identity | maps the central account id → local scope root |
| `token_authenticator` | `nil` | authority: `->(plaintext) { token_or_nil }` |
| `cache_store` | `MemoryStore` | sessions + introspection cache (set to `Rails.cache`) |
| `session_ttl` | `3600` | session sliding TTL (s) |
| `protocol_version` | `nil` (negotiate) | pin an MCP protocol version (satellite/upstream client) |
| `supported_protocol_versions` | `Protocol::SUPPORTED_VERSIONS` | version set the authority dispatcher negotiates |
| `tool_provider` | `nil` | authority: the host's api-agnostic tool catalog (see below) |
| `rate_limiter` / `usage_recorder` / `usage_flusher` | `nil` | authority transport billing hooks (config callables) |
| `parent_controller` | `"ActionController::Base"` | superclass of the engine's controllers, read lazily (set to `"ActionController::API"` for the authority, or `"ApplicationController"` for `helper_method` compat) |
| `account_meta_key` | `"mcp-toolkit/account-id"` | `_meta` key a superuser uses to pin the account |
| `account_id_header` | `"X-MCP-Account-ID"` | header fallback for the account selector |
| `upstreams` | empty registry | gateway: registered upstream MCP servers (register via `register_upstream`) |
| `upstream_timeout` | `10` | gateway: HTTP timeout (s) for calls to an upstream |
| `upstream_list_ttl` | `900` | gateway: TTL (s) for an upstream's cached tool list |
| `logger` | `nil` | optional logger for gateway/session diagnostics (`Rails.logger`) |

## Public API surface

- `McpToolkit.configure { |c| ... }`, `McpToolkit.config`, `McpToolkit.registry`,
  `McpToolkit.reset_config!`
- `McpToolkit::Registry#register(name) { ... }` (DSL: `model`, `serializer`,
  `scope`, `description`, `filterable`, `required_permissions_scope`) +
  `#default_required_permissions_scope`
- `McpToolkit::Serializer::Base` (DSL: `attributes`, `has_one`, `has_many`,
  `translates`)
- `McpToolkit::Server.build(server_context:, config:, extra_tools:)` (satellite,
  SDK-backed)
- `McpToolkit::Engine` (mountable; `mount McpToolkit::Engine => "/mcp"`) +
  `McpToolkit::ServerController` (its controller; parent via `parent_controller`,
  built lazily)
- `McpToolkit::Transport::ControllerMethods` (standalone satellite controller
  concern; override `mcp_config` / `mcp_extra_tools`)
- **Authority dispatch path** (a first-party server serving its own tools +
  upstreams, no SDK): `McpToolkit::Protocol`,
  `McpToolkit::Dispatcher.new(context:, config:)#handle_request`,
  `McpToolkit::Authority::ControllerMethods` (the transport concern, all
  billing/tenancy steps overridable hooks),
  `McpToolkit::Authority::ServerController` (subclassable base),
  `McpToolkit::Authority::Context` (`account` / `principal` / `bearer_token` /
  `superuser?`), `McpToolkit::Tools::AuthorityBase` (optional tool base), and
  `config.tool_provider` (the api-agnostic tool seam)
- `McpToolkit::Session` (opaque `#data` payload, e.g. to bind a session to a token id)
- `McpToolkit::Auth::Introspection` / `Authenticator` (satellite),
  `McpToolkit::Auth::Authority` (authority)
- `McpToolkit::Errors::{InvalidParams, Unauthorized, ConfigurationError}`
- Gateway layer (a central app aggregating/proxying other MCP servers):
  `McpToolkit::Gateway::UpstreamRegistry` (via `config.upstreams` /
  `config.register_upstream`), `McpToolkit::Gateway::{Client, Aggregator, Proxy}`,
  and its errors `McpToolkit::Gateway::{UnknownUpstream, UpstreamCallError}` +
  `McpToolkit::Gateway::Client::Error`
- `McpToolkit::TokensController` — the authority introspection endpoint drawn by
  the engine at `POST /mcp/tokens/introspect`

## Gateway / authority endpoint

Beyond exposing a single server's own tools, the toolkit also ships the generic
**gateway** layer a central app uses to aggregate *other* MCP servers and proxy
calls to them, plus the **authority** introspection endpoint satellites call.
Every app-specific value (the upstream URLs, the account-selector meta key, the
logger, timeouts) is injected via config — nothing here names a deployment.

### Register upstreams

Each upstream has a `key` (the tool-name namespace prefix — its tools surface as
`<key>__<tool>`) and a `url` (its MCP HTTP endpoint). A blank url is ignored, so
an ENV lookup can be passed directly:

```ruby
McpToolkit.configure do |c|
  c.cache_store = Rails.cache          # share the upstream tool-list cache across workers
  c.logger      = Rails.logger         # optional; degrade/recovery diagnostics
  c.register_upstream(key: "notifications", url: ENV["NOTIFICATIONS_SERVER_URL"])
  c.register_upstream(key: "billing",       url: ENV["BILLING_SERVER_URL"])
end
```

### Aggregate upstream tool lists

`Aggregator#tool_definitions` returns every upstream's tools, namespaced, pulled
concurrently. Each upstream's list is cached (`config.upstream_list_ttl`, default
15 min); only a **non-empty** pull is cached, and a failing upstream is omitted
(and logged via `config.logger`) rather than breaking the whole list.

```ruby
definitions = McpToolkit::Gateway::Aggregator.new.tool_definitions(bearer_token: token)
# => [{ "name" => "notifications__list_items", "description" => ..., "inputSchema" => ... }, ...]

McpToolkit::Gateway::Aggregator.new.flush!               # bust every upstream's cache
McpToolkit::Gateway::Aggregator.new.flush!("notifications")  # or just one
```

### Proxy a namespaced call

Split a namespaced tool name via the registry, then proxy it. The caller passes
the already-resolved account id (a scalar); it is forwarded as
`_meta[config.account_meta_key]`.

```ruby
key, bare = McpToolkit.config.upstreams.split_tool_name("notifications__list_items")
proxy = McpToolkit::Gateway::Proxy.new(
  app_key: key, tool_name: bare, account_id: current_account_id, bearer_token: token
)
result = proxy.call({ "since" => "2026-01-01" })   # the upstream's `result` hash, verbatim
```

The proxy is transport-agnostic: an unregistered key raises
`McpToolkit::Gateway::UnknownUpstream`, and an upstream call failure raises
`McpToolkit::Gateway::UpstreamCallError` (carrying the upstream's `jsonrpc_error`
/ `http_status`). Your dispatcher maps those to whatever error shape its transport
speaks — the gem never welds the gateway to a protocol-error class.

### Authority introspection endpoint (built in)

Mounting `McpToolkit::Engine` also draws `POST /mcp/tokens/introspect`, backed by
the gem-provided `McpToolkit::TokensController`. A central app configured with a
`token_authenticator` answers introspection with **no controller of its own** —
the Quickstart 2 hand-rolled controller becomes optional:

```ruby
# config/routes.rb
mount McpToolkit::Engine => "/mcp"   # POST /mcp/tokens/introspect now works
```

Drawing it is safe even on an app that is not an authority: with no
`token_authenticator`, it simply answers `{ "valid": false }`.

## Authority + gateway server (own tools + upstreams, no SDK)

Beyond the SDK-backed satellite path, the toolkit also ships a **hand-rolled
dispatch path** for a first-party server that authenticates tokens LOCALLY and
serves its OWN tools — and, as a gateway, aggregates + proxies upstreams — with
the official `mcp` SDK out of the request path. The gem carries the two dispatch
front-ends side by side: `McpToolkit::Server.build` (satellite) and
`McpToolkit::Dispatcher` (authority). The wire behavior of the authority path —
top-level JSON-RPC tool-error codes, `initialize` capabilities, 3-version
negotiation, verbatim upstream error relay, the custom `list_changed` cache-bust —
is fixed, so a monetized endpoint keeps its byte contract.

### 1. Expose your tools through a provider (the api-agnostic seam)

The gem never sees your API layer. It serves your tools only through a duck-typed
`tool_provider` you register:

```ruby
# provider.tool_definitions(context) -> [{ name:, description:, inputSchema: }]
# provider.find(name)                -> a tool object, or nil
#
# a tool object responds to:
#   #required_permissions_scope -> String | nil     (the gem's per-tool scope gate)
#   #call(context:, **arguments) -> Hash | String   (wrapped into { content: [...] })
McpToolkit.configure do |c|
  c.tool_provider = MyToolProvider.new   # your glue over your own tool classes
end
```

A tool MAY subclass the bundled base (or be any object satisfying the contract):

```ruby
class ListWidgets < McpToolkit::Tools::AuthorityBase
  tool_name "list_widgets"
  description "List widgets for the active account."
  required_permissions_scope "widgets__read"      # gem gates this centrally
  input_schema { { type: "object", properties: { limit: { type: "integer" } } } }

  # `account` / `principal` / `bearer_token` / `superuser?` come from the context.
  def call(limit: 25)
    Widget.for(account).limit(limit).map(&:as_json)  # your domain, behind #call
  end
end
```

`context` is an `McpToolkit::Authority::Context` (`account`, `principal`,
`bearer_token`, `superuser?`). It is re-created for EVERY JSON-RPC call — including
each element of a batch — so a mixed-account batch resolves the right account per
call.

### 2. Serve it through the authority transport

A **pure host** mounts the engine's authority base and drives everything from
config callables. A host whose rate-limit / usage / account logic touches its own
models **subclasses** the base and overrides the hook methods:

```ruby
class ServerController < McpToolkit::Authority::ServerController
  # Local token auth, session binding, and account resolution have working
  # defaults (duck-typed on your token via config.token_authenticator). Override
  # only what touches your models:
  def mcp_rate_limit!
    # ...your limiter; render + halt when over the limit...
  end

  def mcp_track_usage(request_data, account)
    # ...accumulate one usage row for this call (fires per batch element)...
  end

  def mcp_flush_usage        = # ...bulk-insert the accumulated rows...
  def mcp_session_data       = { token_id: mcp_principal.id }  # revoked token kills the session
end
```

Every billing/tenancy step is an overridable hook: `mcp_authenticate!`,
`mcp_rate_limit!`, `mcp_track_usage`, `mcp_flush_usage`, `mcp_resolve_account`,
`mcp_session_data`, `mcp_dispatch`, `mcp_health_payload`, `mcp_config`. The
per-request loop (`resolve account → track usage → dispatch`) is preserved across
batches, so usage metering survives a mixed-account batch.

Point your `POST /mcp` route at the subclass (or mount the engine for a pure host);
keep `POST /mcp/tokens/introspect` on the gem's `TokensController`.

### Lazy `parent_controller`

The gem's controllers subclass `config.parent_controller`. That parent is read
only at **build** time — the controllers are built by
`McpToolkit.build_engine_controllers!`, triggered lazily on first reference and
reset on each reload by the engine's `to_prepare` — so it is always resolved AFTER
your app's initializers/to_prepare. Your whole MCP initializer can therefore live
in `to_prepare`. Set `c.parent_controller = "ActionController::API"` for the
authority.

## Development

```bash
bin/setup
bundle exec rspec
```

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
