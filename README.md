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
| `generic_tool_name_prefix` | `""` | authority: prefix namespacing the four generic Registry-backed tools (e.g. `"foo_"` → `foo_resources` …) |
| `rate_limiter` / `usage_recorder` / `usage_flusher` | `nil` | authority transport billing hooks (config callables) |
| `rate_limit_max_requests` | `nil` (off) | authority: per-principal request cap for the built-in `RateLimiter`; `nil` disables rate limiting |
| `rate_limit_window` | `3600` | authority: fixed rate-limit window (s); ignored while `rate_limit_max_requests` is `nil` |
| `superuser_resolver` | `nil` | optional `->(principal) -> Boolean` for `Context#superuser?`; `nil` = duck-type `principal.superuser?` |
| `parent_controller` | `"ActionController::Base"` | superclass of the engine's controllers, read lazily (set to `"ActionController::API"` for the authority, or `"ApplicationController"` for `helper_method` compat) |
| `account_meta_key` | `"mcp-toolkit/account-id"` | `_meta` key a superuser uses to pin the account |
| `account_id_header` | `"X-MCP-Account-ID"` | header fallback for the account selector |
| `upstreams` | empty registry | gateway: registered upstream MCP servers (register via `register_upstream`; pass `public_tool_list: false` for a caller-dependent list to opt out of the shared cache) |
| `upstream_timeout` | `10` | gateway: HTTP timeout (s) for calls to an upstream |
| `upstream_list_ttl` | `900` | gateway: TTL (s) for an upstream's cached tool list |
| `logger` | `nil` | optional logger for gateway/session diagnostics (`Rails.logger`) |

## Public API surface

- `McpToolkit.configure { |c| ... }`, `McpToolkit.config`, `McpToolkit.registry`,
  `McpToolkit.reset_config!`
- `McpToolkit::Registry#register(name) { ... }` (DSL: `model`, `serializer`,
  `scope`, `description`, `note`, `filterable`, `filter(name, type:, description:,
  &applier)`, `superusers_only!`, `required_permissions_scope`) +
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
  `superuser?`), `McpToolkit::Tools::AuthorityBase` (optional tool base),
  `config.tool_provider` (the api-agnostic tool seam),
  `McpToolkit::Authority::RegistryToolProvider.new(config:)` (serves the four
  generic Registry-backed tools `resources` / `resource_schema` / `get` / `list`,
  reusing the executors + schema builder) +
  `McpToolkit::Authority::CompositeToolProvider.new(*providers)` (compose it with
  bespoke tools)
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

The cache is keyed by upstream only, so it rests on a registration **contract**:
an upstream's `tools/list` must be **caller-independent** (the same public tools
for every valid token; scope enforced only at call time). An upstream that
filters its list by the caller's privilege (e.g. hides superuser-only tools) must
register `public_tool_list: false` — it is then pulled live per request and never
cached, so a privileged caller's list can't leak to an unprivileged one.

```ruby
c.register_upstream(key: "gateway", url: ENV["GATEWAY_SERVER_URL"], public_tool_list: false)
```

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

### OAuth authorization bridge (authority-only, opt-in)

Some MCP clients will not accept a token you hand them. They authenticate one way
only: discover an authorization server, run an authorization-code + PKCE flow in a
browser, and use whatever `access_token` comes back. The MCP authorization spec
also forbids a token in the request URI, so `?token=<...>` is not a fallback for
them either. If your tokens are issued out-of-band — an admin UI, a CLI, a support
process — those clients cannot reach your server at all.

The bridge is a standards-shaped **envelope around the tokens you already issue**.
It is not an identity provider: its authorization page asks the operator to paste
an access token they already hold, and the `access_token` it returns **is that
token**, verified through the same `token_authenticator` your transport uses.
Scopes, expiry, revocation and tenancy stay exactly where you put them, and it
creates no new way to obtain a token.

```ruby
# config/initializers/mcp_toolkit.rb
McpToolkit.configure do |c|
  c.auth_role = :authority
  c.token_authenticator = ->(plaintext) { AccessToken.authenticate(plaintext) }

  # REQUIRED for the bridge on any multi-worker deployment. The default is an
  # in-process MemoryStore, which cannot carry an authorization code from the
  # worker that issues it to the worker that redeems it — the flow then fails
  # intermittently, *after* the operator has pasted their token.
  c.cache_store = Rails.cache

  # Naming who may receive an authorization code is what switches the bridge on.
  c.oauth_allowed_redirect_uris = ["https://client.example/callback"]
  c.oauth_resource_path = "/mcp" # must match the engine's mount point

  # Optional: let any MCP client running on your operators' OWN machines connect
  # without an allowlist entry each (RFC 8252 — see below). This is an opt-in
  # signal in its own right, so it alone can switch the bridge on.
  c.oauth_allow_loopback_redirects = true
end
```

```ruby
# config/routes.rb — the helper call must be TOP LEVEL. A `/.well-known/*` path
# cannot be drawn by an engine mounted under a path, so the metadata routes have
# to live in your own route set. A no-op unless the bridge is configured.
Rails.application.routes.draw do
  McpToolkit.draw_oauth_metadata_routes(self)
  mount McpToolkit::Engine => "/mcp"
end
```

That yields the whole flow — `GET /.well-known/oauth-protected-resource/mcp`,
`GET /.well-known/oauth-authorization-server/mcp`, `POST /mcp/oauth/register`,
`GET`/`POST /mcp/oauth/authorize`, `POST /mcp/oauth/token` — plus a
`WWW-Authenticate: Bearer resource_metadata="..."` header on the transport's 401,
which is what makes a client start the flow at all. Every identifier is derived
from the live request origin, so each host name your app answers on works with no
further configuration.

**What is deliberately absent**, because none of it gates anything here: client
registration returns an identifier and stores nothing (no endpoint reads a
`client_id`); there is no consent step (pasting a token you hold *is* the grant);
no refresh token is issued (the pasted token's own expiry is the real lifetime, so
a client re-runs the flow instead of refreshing a shadow of it).

**What is not faked**, because faking either would be a real vulnerability rather
than a skipped ceremony: `redirect_uri` is checked against your policy on both
legs (below), and the PKCE `code_verifier` is verified against the stored S256
challenge in constant time.

### Which clients may receive a code

This is the bridge's load-bearing control, so it is worth knowing why it is shaped
the way it is. The authorization page is served from **your** origin under **your**
certificate and asks an operator to paste a live token. So an unvetted
`redirect_uri` does not merely add an open redirect — it makes your own domain a
credential-phishing page: an attacker sends the operator an authorize link
carrying the attacker's own `code_challenge`, the operator pastes, the code is
delivered to the attacker, and they redeem it with the verifier they chose. PKCE
does not help (they own the verifier), nor does the single-use code, nor
re-verifying the token. A full authorization server blocks this with a consent
screen naming the client plus an authenticated session; this bridge mocks both
away, which is exactly what the redirect policy compensates for.

So **every target must be named by exact string**, with exactly one exception:

| Target | Rule | Why |
|---|---|---|
| Anything remote (`https://client.example/cb`) | Exact string, in `oauth_allowed_redirect_uris` | The phishing vector. Never opened up. |
| Private-use scheme (`cursor://…`, `com.example.app:/cb`) | Exact string, in `oauth_allowed_redirect_uris` | Keeps the code on the device, but its URI is a fixed string — so just name it. |
| Loopback (`http://127.0.0.1:*`, `localhost`, `[::1]`) | `oauth_allow_loopback_redirects` | The only target that **cannot** be named: the client picks an ephemeral port at runtime (RFC 8252 §7.3). And it resolves on the operator's own machine, so the attack above cannot reach it. |

The loopback exception exists because an allowlist entry is *impossible* there,
not because native clients are trusted. A private-use scheme keeps the code on the
device too, but nothing forces it to be unnamed — and whole **schemes** cannot be
accepted generically anyway: telling a private-use scheme from a registered
network one (`ssh:`, `ldap:`, `gopher:` — each naming a **remote** host) would
mean enumerating the IANA registry, and a denylist of the ones you happened to
think of is the shape that fails open.

Loopback is judged on the *parsed* URI, so `http://127.0.0.1@evil.example/` (host
`evil.example`) and `http://127.0.0.1.evil.example/` are both correctly seen as
remote, and a fragment is refused.

**What the allowlist does not cover.** It binds which URL a code may be sent to —
not *whose session at that URL* receives it. A hosted MCP client is one callback
shared by every one of its users, so an attacker can start a flow in their own
account there, send an operator the resulting authorize link, and have the code
land back at that client carrying the attacker's `state`. Whether the operator's
token then ends up in the attacker's account is decided by whether **the client**
binds `state` to the browser session that began the flow (RFC 6819 §4.4.1.7). An
authorization server cannot bind a code to a session it never saw, so this is not
something the bridge — or a full authorization server, which has the identical
exposure — can close. **Only allowlist clients you believe handle `state`
correctly.**

### Deployment note

Every identifier the bridge publishes is derived from the live request origin
(`request.base_url`), which honours `X-Forwarded-Host`. **You MUST pin
`config.hosts`** so Rails' `HostAuthorization` rejects a forged header before it
reaches the bridge — Rails does *not* do this for you: it populates `config.hosts`
in development and leaves it **empty in production**, where empty means no
checking at all. Both metadata documents are served
`Cache-Control: no-store` regardless, so no shared cache can hand one client an
origin another client chose.

**Serve it over HTTPS** (`config.force_ssl = true`). The authorization page
receives a live access token in a POST body; on cleartext that token is on the
wire. The gem refuses a cleartext remote `redirect_uri` in the allowlist for the
same reason, but it cannot make your own origin HTTPS for you.

The engine adds `access_token` and `code_verifier` to `config.filter_parameters`
itself, so the pasted token stays out of your logs even on a host that ships no
filter list of its own — nothing to configure.

**It is additive to an OAuth provider you already run, and it claims nothing
origin-global.** The flow endpoints live under the engine's mount
(`/mcp/oauth/*`), so if you already serve OAuth at the conventional top-level
`/oauth/*` — as an app with Doorkeeper for its own API does — you keep every one of
those routes.

The metadata documents are **path-scoped** to the mount
(`/.well-known/oauth-protected-resource/mcp`), never the bare
`/.well-known/oauth-authorization-server`. That matters: the bare paths are
origin-global and mean *"the authorization server of this whole origin"*, which
belongs to a provider you already run, not to an MCP server sharing the host.
RFC 8414 §3.1 exists for exactly this — *"Using path components enables supporting
multiple issuers per host"* — and the MCP authorization spec (2025-11-25) requires
a client given a path-ful issuer to try the path-**inserted** URLs, with no root
fallback. So the issuer is your MCP endpoint URL, and both documents hang off it.

If your MCP endpoint IS its origin root (a dedicated MCP domain), there is no path
to insert and you get the bare paths — correct there, since your server really is
that origin's only authorization server. Set `oauth_resource_path = "/"`.

`oauth_allowed_redirect_uris` is empty and `oauth_allow_loopback_redirects`
is off by default, which leaves `config.oauth_bridge?` false and the routes
undrawn — the bridge cannot run without bounds on where codes may go. A satellite
never draws it at all (its tokens belong to its central app, so there is nothing
for it to authorize against), and neither does an authority with no
`token_authenticator`, since the bridge verifies the pasted token through it on
both legs and could not work without one.

The bridge's controller has its **own** parent, `config.oauth_parent_controller`
(default `ActionController::Base`), deliberately separate from the
`parent_controller` your transport uses. The transport is a JSON-only endpoint you
may well have pointed at `ActionController::API`, which cannot render an HTML view
— and the authorization page is one. Keeping them apart means enabling the bridge
changes nothing about your transport. Point it at your own `ApplicationController`
to inherit branding; the page renders with `layout: false` either way, so an app
layout that needs asset-pipeline context is not pulled in.

To restyle the page, define your own `app/views/mcp_toolkit/oauth/authorize.html.erb`
— your app's view path takes precedence over the engine's.

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

#### Or serve the generic Registry-backed tools

If your tools are just account-scoped, read-only views over models, you don't need
to hand-write them. Register each as a resource (exactly as on the satellite side)
and let the bundled provider serve the same four generic tools — `resources`,
`resource_schema`, `get`, `list` — over the authority dispatcher:

```ruby
McpToolkit.configure do |c|
  c.registry.register(:widgets) do
    model Widget
    serializer WidgetSerializer                 # any class satisfying the serializer contract
    description "Widgets for the active account."
    filterable status: :status, owner_id: :owner_id
    # A resource-specific ("custom") filter: an arbitrary block, keyed by a
    # top-level request param, that the generic equality allowlist can't express.
    filter :for_project, type: :integer, description: "Only widgets in this project" do |relation, id|
      relation.joins(:board).where(boards: { project_id: id })
    end
    superusers_only!                            # optional: refuse/hide for non-superuser tokens
    note "Read-only projection; do not interpret status codes without domain context."
    scope { |account| Widget.where(account_id: account.id) }
  end

  # The generic tools, served over config.registry:
  c.tool_provider = McpToolkit::Authority::RegistryToolProvider.new(config: c)
end
```

Each generic tool resolves the `resource` argument against the registry, refuses a
`superusers_only!` resource for a non-superuser (and hides it from `resources`),
enforces the resource's `required_permissions_scope`, and requires a resolved
account for `get` / `list`. `resource_schema` advertises each attribute's filter
`operators` and the resource `note`.

By default the four tools advertise their bare names (`resources`,
`resource_schema`, `get`, `list`). To **namespace** them — e.g. to keep a stable,
host-specific name for existing clients, or to run several MCP surfaces without
name collisions — set a prefix:

```ruby
c.generic_tool_name_prefix = "foo_"   # advertised + resolved as foo_resources,
                                      # foo_resource_schema, foo_get, foo_list
```

The prefix applies only to these four generic tools; a composed bespoke provider's
own tool names are unaffected.

To serve the generic tools **and** your own bespoke tools behind one provider,
compose them:

```ruby
c.tool_provider = McpToolkit::Authority::CompositeToolProvider.new(
  McpToolkit::Authority::RegistryToolProvider.new(config: c),
  MyBespokeToolProvider.new                    # e.g. an audit/versions tool
)
```

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

**Rate limiting is built in.** Set `config.rate_limit_max_requests` (and,
optionally, `config.rate_limit_window`, default 1 hour) and the default
`mcp_rate_limit!` throttles each principal via `McpToolkit::RateLimiter` against
`config.cache_store` — no subclass needed. It sets the `X-RateLimit-*` headers on
every capped response and, over the limit, renders a JSON-RPC `-32029` error at
`429` with `Retry-After`. A host that keeps its cap in a constant/model overrides
the small `mcp_rate_limit_max_requests` hook (default `config.rate_limit_max_requests`);
`mcp_rate_limit_key` (default `mcp_principal.id`) buckets the counter. Leaving the
cap `nil` disables throttling entirely; `config.rate_limiter` stays as an escape
hatch that replaces the built-in wholesale.

**Superuser is an optional, first-class concept.** Set
`config.superuser_resolver = ->(principal) { ... }` and `Context#superuser?` uses
it to gate `superusers_only!` resources; with no resolver it duck-types
`principal.superuser?`, and with neither, no caller is ever a superuser.

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
