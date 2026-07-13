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
  def self.create!(data: {}, config: McpToolkit.config)
    id = SecureRandom.uuid
    config.cache_store.write(cache_key(id, config), dump(data, config), expires_in: config.session_ttl)
    new(id:, data:)
  end

  def self.find(id, config: McpToolkit.config)
    return nil if id.to_s.empty?

    stored = config.cache_store.read(cache_key(id, config))
    return nil unless stored

    # Sliding expiry: bump TTL on every successful lookup. The RAW stored hash
    # is re-written untouched, so under a custom payload codec every
    # application version keeps reading a format it understands.
    config.cache_store.write(cache_key(id, config), stored, expires_in: config.session_ttl)
    new(id:, data: load_data(stored, config))
  end

  def self.delete(id, config: McpToolkit.config)
    return false if id.to_s.empty?

    config.cache_store.delete(cache_key(id, config))
  end

  # The key namespace comes from config so a host can keep a pre-gem namespace
  # (see Configuration#session_key_prefix) and share live sessions across old
  # and new application versions during a rolling deploy.
  def self.cache_key(id, config)
    "#{config.session_key_prefix}#{id}"
  end
  private_class_method :cache_key

  # The stored payload defaults to the gem's `{ created_at:, data: }` format; a
  # host migrating a pre-gem session store injects a dumper/loader pair to keep
  # the historical wire format (see Configuration#session_payload_dumper).
  def self.dump(data, config)
    return config.session_payload_dumper.call(data) if config.session_payload_dumper

    { created_at: Time.now.to_i, data: }
  end
  private_class_method :dump

  def self.load_data(stored, config)
    return config.session_payload_loader.call(stored) || {} if config.session_payload_loader

    # `data` defaults to {} for legacy rows written before the payload existed.
    stored[:data] || {}
  end
  private_class_method :load_data

  attr_reader :id, :data

  def initialize(id:, data: {})
    @id = id
    @data = data || {}
  end
end
