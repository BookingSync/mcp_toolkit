# frozen_string_literal: true

# SATELLITE side. Authenticates the bearer token the central app forwards by
# calling the central app's introspection endpoint, with a short-TTL cache so a
# burst of tool calls in one session does not hammer the central app.
#
#   POST {central_app_url}{introspect_path}
#   Authorization: Bearer <token>
#
# Response contract (the AUTHORITY emits this; see Auth::Authority):
#   { valid: bool,
#     kind: <one of McpToolkit::TokenKinds — accounts-user or superuser>,
#     account_id: <id|null>,
#     account_ids: [...],
#     expires_at: <iso8601|null>,
#     scopes: [...] }   # OAuth-style `<app>__<action>` scopes a token carries
#
# Authorization is purely scope-based: a token reaches a tool when it carries the
# scope that tool explicitly requires (declared per resource via
# `required_permissions_scope`, or the registry default; enforced in
# Tools::Base#with_account / #with_authentication via `authorized_for_scope?`).
#
# The cache is keyed on a SHA-256 of the token (never the plaintext) so cached
# entries can't be reversed back to a usable credential from cache storage. The
# HTTP call itself is delegated to Auth::AuthorityServerClient.
class McpToolkit::Auth::Introspection
  CACHE_PREFIX = "mcp_toolkit:introspection:"

  Result = Struct.new(
    :valid, :kind, :account_id, :account_ids, :expires_at, :scopes, keyword_init: true
  ) do
    # Locally enforce the authority's `expires_at` (defense-in-depth): a token is
    # only valid when the authority said so AND it has not lapsed. Without this,
    # validity would rest solely on the authority's `valid: true` boolean, so a
    # stale `valid: true` (e.g. a clock-skewed or buggy authority, or a cached
    # Result) with a past `expires_at` would be accepted indefinitely.
    def valid?
      valid == true && !expired?
    end

    # True when `expires_at` is present and now is at/after it. Blank/nil means
    # the token has no expiry (=> not expired). An UNPARSEABLE `expires_at` is
    # treated as expired (fail-closed) rather than silently accepted. Kept public
    # for clarity/testability.
    def expired?
      raw = expires_at
      return false if raw.nil? || raw.to_s.strip.empty?

      expiry = parse_expiry(raw)
      return true if expiry.nil? # unparseable => fail closed

      expiry <= Time.now
    end

    private

    def parse_expiry(raw)
      return raw if raw.is_a?(Time)

      Time.iso8601(raw.to_s)
    rescue ArgumentError, TypeError
      begin
        Time.parse(raw.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end

    public

    def accounts_user?
      kind.to_s == McpToolkit::TokenKinds::ACCOUNTS_USER
    end

    def superuser?
      kind.to_s == McpToolkit::TokenKinds::USER
    end

    # True when the token carries the EXACT `required_scope` (e.g.
    # `notifications__read`). An empty required scope passes (a tool that
    # requires no scope is reachable by any valid token). A non-empty required
    # scope must be present in the token's `scopes`; empty token scopes are
    # therefore unrestricted ONLY for tools that require no scope.
    def authorized_for_scope?(required_scope)
      return true if required_scope.to_s.empty?

      scope_list = Array(scopes).map(&:to_s)
      scope_list.include?(required_scope.to_s)
    end

    # Account ids are STRING-normalized for comparison: the contract allows
    # integer OR string/UUID ids, so coercing to_i would collapse every
    # non-numeric id to 0 and let unrelated accounts match. Strings compare
    # safely and the resolver's `find_by(synced_id:)` coerces back per-column.
    def authorized_account_ids
      Array(account_ids).map(&:to_s)
    end
  end

  INVALID = Result.new(valid: false).freeze

  # Returns an Introspection::Result. Invalid/expired/unreachable => a result
  # whose `valid?` is false. Caches positive AND negative results briefly.
  def self.call(token, config: McpToolkit.config)
    new(token, config:).call
  end

  def initialize(token, config: McpToolkit.config)
    @token = token
    @config = config
  end

  def call
    return INVALID if token.to_s.empty?

    cached = cache.read(cache_key)
    return cached if cached

    result = fetch
    cache.write(cache_key, result, expires_in: config.introspection_cache_ttl)
    result
  end

  private

  attr_reader :token, :config

  def fetch
    body = authority_server_client.introspect(token)
    return INVALID if body.nil?

    parse(body)
  end

  def parse(body)
    payload = body.is_a?(Hash) ? body : JSON.parse(body)
    return INVALID unless payload["valid"] == true

    Result.new(
      valid: true,
      kind: payload["kind"],
      account_id: payload["account_id"],
      account_ids: payload["account_ids"],
      expires_at: payload["expires_at"],
      scopes: payload["scopes"]
    )
  rescue JSON::ParserError
    INVALID
  end

  def authority_server_client
    McpToolkit::Auth::AuthorityServerClient.new(config)
  end

  def cache
    config.cache_store
  end

  def cache_key
    "#{CACHE_PREFIX}#{Digest::SHA256.hexdigest(token)}"
  end
end
