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
  c.server_name          = "bsa-notifications-mcp"
  c.server_instructions  = "Read-only access to this account's notifications domain."

  # --- satellite auth ---
  c.auth_role            = :satellite
  c.central_app_url      = ENV.fetch("MCP_CENTRAL_APP_URL") # POSTs <url>/mcp/tokens/introspect

  # The scope every tool requires, declared ONCE for all resources. A resource
  # can override it per-resource (see below). Omit entirely for "no scope
  # required". Whether a scope is required is PER TOOL — there is no app-wide
  # permission flag.
  c.registry.default_required_permissions_scope "notifications__read"

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

  McpToolkit.registry.register(:notifications) do
    model       Notification
    serializer  Mcp::NotificationSerializer        # your serializer (see below)
    description "Email notification templates + their scheduling rules."
    scope(&:notifications)                          # account.notifications
  end

  McpToolkit.registry.register(:scheduled_notifications) do
    model       ScheduledNotification
    serializer  Mcp::ScheduledNotificationSerializer
    description "Scheduled mailings."
    # Expose a public filter key that maps to a synced storage column:
    filterable  booking_id: :synced_booking_id
    # Override the registry default scope for just this resource (optional):
    required_permissions_scope "notifications__read"
    scope { |account| ScheduledNotification.where(synced_account_id: account.synced_id) }
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

**1. Configure** the local token lookup (your `McpToken.authenticate` equivalent):

```ruby
McpToolkit.configure do |c|
  c.auth_role          = :authority
  c.token_authenticator = ->(plaintext) { McpToken.authenticate(plaintext) }
  c.cache_store        = Rails.cache
end
```

The token object your authenticator returns must respond to:
`kind` (`:accounts_user` | `:user`), `account_id`, `account_ids`, `expires_at`
(an `#iso8601`-able time or nil), and `scopes` (an array of `<app>__<action>`
scopes; `[]` = no scopes). Optionally `touch_last_used!`. A typical app token
model (e.g. `McpToken`) fits.

**2. Expose the introspection endpoint** the satellites call:

```ruby
class Mcp::TokensController < ActionController::API
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
post "mcp/tokens/introspect", to: "mcp/tokens#introspect"
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
class Mcp::NotificationSerializer < McpToolkit::Serializer::Base
  attributes :id, :name, :active, :created_at, :updated_at
  translates :subject, :template_html         # Globalize-backed { locale => value }

  has_one  :account, foreign_key: :synced_account_id
  has_one  :mail_layout
  has_many :scheduled_notifications
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
| `protocol_version` | `nil` (negotiate) | pin an MCP protocol version |
| `parent_controller` | `"ActionController::Base"` | superclass of the engine's `ServerController` (set to `"ApplicationController"` for `helper_method` compat) |
| `account_meta_key` | `"mcp-toolkit/account-id"` | `_meta` key a superuser uses to pin the account |
| `account_id_header` | `"X-MCP-Account-ID"` | header fallback for the account selector |

## Public API surface

- `McpToolkit.configure { |c| ... }`, `McpToolkit.config`, `McpToolkit.registry`,
  `McpToolkit.reset_config!`
- `McpToolkit::Registry#register(name) { ... }` (DSL: `model`, `serializer`,
  `scope`, `description`, `filterable`, `required_permissions_scope`) +
  `#default_required_permissions_scope`
- `McpToolkit::Serializer::Base` (DSL: `attributes`, `has_one`, `has_many`,
  `translates`)
- `McpToolkit::Server.build(server_context:, config:, extra_tools:)`
- `McpToolkit::Engine` (mountable; `mount McpToolkit::Engine => "/mcp"`) +
  `McpToolkit::ServerController` (its controller; parent via `parent_controller`)
- `McpToolkit::Transport::ControllerMethods` (standalone controller concern;
  override `mcp_config` / `mcp_extra_tools`)
- `McpToolkit::Session`
- `McpToolkit::Auth::Introspection` / `Authenticator` (satellite),
  `McpToolkit::Auth::Authority` (authority)
- `McpToolkit::Errors::{InvalidParams, Unauthorized, ConfigurationError}`

## Scope (what's intentionally NOT here)

The gateway / upstream-aggregation layer (a central app's `Mcp::Upstreams*`) is
**out of scope** — it's core-only and ships to no satellite. This toolkit is for
servers that expose tools, not for aggregating other servers.

## Development

```bash
bin/setup
bundle exec rspec
```

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
