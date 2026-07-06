# frozen_string_literal: true

# The per-JSON-RPC-request context the authority transport threads into the
# dispatcher and, through it, into each host tool. Re-created for EVERY element of
# a batch so each call carries its own resolved account (the property usage
# metering relies on).
#
# It carries three host-supplied values and derives one:
#   * `account`      — the tenant resolved for THIS call (nil when none applies).
#                      The object need only respond to `#id` (forwarded upstream
#                      as the account selector).
#   * `principal`    — the authenticated caller (the token object). Duck-typed;
#                      the gem calls `#authorized_for_scope?(scope)` (tool scope
#                      gate) and, optionally, `#superuser?` (see `#superuser?`).
#                      The transport's account resolution additionally uses
#                      `#default_account` / `#authorize_account(id)`.
#   * `bearer_token` — the raw bearer, forwarded to upstream MCP servers so they
#                      introspect the same token and resolve the same account.
#   * `superuser?`   — derived: true only when the principal responds to
#                      `#superuser?` truthily. Lets a host tool base
#                      (McpToolkit::Tools::AuthorityBase) gate superuser-only
#                      resources without the gem naming any app concept.
class McpToolkit::Authority::Context
  attr_reader :account, :principal, :bearer_token

  def initialize(account:, principal:, bearer_token: nil)
    @account = account
    @principal = principal
    @bearer_token = bearer_token
  end

  def superuser?
    principal.respond_to?(:superuser?) && !!principal.superuser?
  end
end
