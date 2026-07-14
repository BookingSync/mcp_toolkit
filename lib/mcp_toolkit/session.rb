# frozen_string_literal: true

# Server-side session for the MCP Streamable HTTP transport: created on
# `initialize`, identified by an opaque `Mcp-Session-Id` header the client echoes
# on every later request, stored in the configured cache with a sliding TTL.
#
# Cache-backed (rather than the gem's in-process StreamableHTTPTransport) so
# sessions survive across Puma workers and interoperate with a gateway's client.
# The cache store + TTL come from McpToolkit.config.
#
# A session carries an opaque `data` hash the transport can attach at creation
# (e.g. `{ token_id: ... }`) so an AUTHORITY can bind a session to a token id —
# the property that lets a revoked token kill an in-flight session. The gem does
# NOT interpret `data` (it never re-resolves a token; that's the consumer's auth
# concern): it stores it, round-trips it, and exposes it via `#data`.
class McpToolkit::Session
  CACHE_KEY_PREFIX = "mcp_toolkit:session:"

  def self.create!(data: {}, config: McpToolkit.config)
    id = SecureRandom.uuid
    config.cache_store.write(cache_key(id), { created_at: Time.now.to_i, data: }, expires_in: config.session_ttl)
    new(id:, data:)
  end

  def self.find(id, config: McpToolkit.config)
    return nil if id.to_s.empty?

    stored = config.cache_store.read(cache_key(id))
    return nil unless stored

    # Sliding expiry: bump TTL on every successful lookup, re-writing the row
    # untouched.
    config.cache_store.write(cache_key(id), stored, expires_in: config.session_ttl)
    new(id:, data: stored[:data] || {})
  end

  def self.delete(id, config: McpToolkit.config)
    return false if id.to_s.empty?

    config.cache_store.delete(cache_key(id))
  end

  def self.cache_key(id)
    "#{CACHE_KEY_PREFIX}#{id}"
  end
  private_class_method :cache_key

  attr_reader :id, :data

  def initialize(id:, data: {})
    @id = id
    @data = data || {}
  end
end
