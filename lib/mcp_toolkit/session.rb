# frozen_string_literal: true

require "securerandom"

module McpToolkit
  # Server-side session for the MCP Streamable HTTP transport: created on
  # `initialize`, identified by an opaque `Mcp-Session-Id` header the client echoes
  # on every later request, stored in the configured cache with a sliding TTL.
  #
  # Cache-backed (rather than the gem's in-process StreamableHTTPTransport) so
  # sessions survive across Puma workers and interoperate with a gateway's client.
  # Extracted from bsa-notifications' `McpServer::Session`, made config-driven
  # (cache store + TTL come from McpToolkit.config).
  class Session
    CACHE_KEY_PREFIX = "mcp_toolkit:session:"

    class << self
      def create!(config: McpToolkit.config)
        id = SecureRandom.uuid
        config.cache_store.write(cache_key(id), { created_at: Time.now.to_i }, expires_in: config.session_ttl)
        new(id:)
      end

      def find(id, config: McpToolkit.config)
        return nil if id.to_s.empty?

        data = config.cache_store.read(cache_key(id))
        return nil unless data

        # Sliding expiry: bump TTL on every successful lookup.
        config.cache_store.write(cache_key(id), data, expires_in: config.session_ttl)
        new(id:)
      end

      def delete(id, config: McpToolkit.config)
        return false if id.to_s.empty?

        config.cache_store.delete(cache_key(id))
      end

      private

      def cache_key(id)
        "#{CACHE_KEY_PREFIX}#{id}"
      end
    end

    attr_reader :id

    def initialize(id:)
      @id = id
    end
  end
end
