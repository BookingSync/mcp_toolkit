# frozen_string_literal: true

require "digest"
require "json"
require "faraday"

module McpToolkit
  module Auth
    # SATELLITE side. Authenticates the bearer token the central app forwards by
    # calling the central app's introspection endpoint, with a short-TTL cache so a
    # burst of tool calls in one session does not hammer the central app.
    #
    #   POST {central_app_url}{introspect_path}
    #   Authorization: Bearer <token>
    #
    # Response contract (the AUTHORITY emits this; see Auth::IntrospectionPayload):
    #   { valid: bool,
    #     kind: "accounts_user" | "user",
    #     account_id: <id|null>,
    #     account_ids: [...],
    #     expires_at: <iso8601|null>,
    #     scopes: [...] }   # OAuth-style `<app>_<action>` scopes; [] / null = unrestricted
    #
    # `applications` may still appear for backward-compat but is no longer used for
    # authorization — app-reach and per-action authorization both derive from
    # `scopes` now.
    #
    # The cache is keyed on a SHA-256 of the token (never the plaintext) so cached
    # entries can't be reversed back to a usable credential from cache storage.
    #
    # Extracted from bsa-notifications' `McpServer::Introspection`, made
    # config-driven (URL / required application / cache / timeouts come from
    # McpToolkit.config).
    class Introspection
      CACHE_PREFIX = "mcp_toolkit:introspection:"

      Result = Struct.new(
        :valid, :kind, :account_id, :account_ids, :expires_at, :applications, :scopes, keyword_init: true
      ) do
        def valid?
          valid == true
        end

        def accounts_user?
          kind.to_s == "accounts_user"
        end

        def superuser?
          kind.to_s == "user"
        end

        # True when the token can reach `required_application` (or when no required
        # application is configured — then any valid token passes). App-reach is
        # derived from the token's `scopes` of the form `<app>_<action>`: a token
        # reaches an app if it carries any scope for that app. NULL/empty scopes =
        # unrestricted (backward-compat).
        def authorized_for_application?(required_application)
          return true if required_application.to_s.empty?

          scope_list = Array(scopes).map(&:to_s)
          return true if scope_list.empty? # unrestricted token

          app = required_application.to_s
          scope_list.any? { |s| s == app || s.start_with?("#{app}_") }
        end

        # True when the token carries the EXACT `required_scope` (e.g.
        # `notifications_read`). NULL/empty scopes = unrestricted (backward-compat);
        # an empty required scope passes.
        def authorized_for_scope?(required_scope)
          return true if required_scope.to_s.empty?

          scope_list = Array(scopes).map(&:to_s)
          return true if scope_list.empty? # unrestricted token

          scope_list.include?(required_scope.to_s)
        end

        def authorized_account_ids
          Array(account_ids).map(&:to_i)
        end
      end

      INVALID = Result.new(valid: false).freeze

      class << self
        # Returns an Introspection::Result. Invalid/expired/unreachable => a result
        # whose `valid?` is false. Caches positive AND negative results briefly.
        def call(token, config: McpToolkit.config)
          new(token, config:).call
        end
      end

      def initialize(token, config: McpToolkit.config)
        @token = token
        @config = config
      end

      def call
        return INVALID if @token.to_s.empty?

        cached = cache.read(cache_key)
        return cached if cached

        result = fetch
        cache.write(cache_key, result, expires_in: @config.introspection_cache_ttl)
        result
      end

      private

      def fetch
        response = connection.post(@config.introspect_url) do |request|
          request.headers["Authorization"] = "Bearer #{@token}"
          request.headers["Accept"] = "application/json"
        end

        return INVALID unless response.status == 200

        parse(response.body)
      rescue Faraday::Error
        INVALID
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
          applications: payload["applications"],
          scopes: payload["scopes"]
        )
      rescue JSON::ParserError
        INVALID
      end

      def cache
        @config.cache_store
      end

      def cache_key
        "#{CACHE_PREFIX}#{Digest::SHA256.hexdigest(@token)}"
      end

      def connection
        timeout = @config.introspection_timeout
        Faraday.new do |conn|
          conn.options.timeout = timeout
          conn.options.open_timeout = timeout
          conn.response :json, content_type: /\bjson$/
          conn.adapter Faraday.default_adapter
        end
      end
    end
  end
end
