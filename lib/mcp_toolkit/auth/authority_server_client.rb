# frozen_string_literal: true

require "faraday"

# SATELLITE side. The HTTP client that talks to the central authority's
# introspection endpoint. Owns the Faraday connection (timeouts, JSON parsing,
# adapter) and the POST itself, so Auth::Introspection is left with the caching
# and result-parsing concerns only.
#
#   POST {config.introspect_url}
#   Authorization: Bearer <token>
#   Accept: application/json
#
# Returns the raw response body on a 200, or nil otherwise (a non-200 status or a
# transport-level Faraday error). Auth::Introspection turns that into an
# Introspection::Result.
class McpToolkit::Auth::AuthorityServerClient
  def initialize(config)
    @config = config
  end

  # POSTs the token to the authority's introspection endpoint. Returns the
  # response body on a 200; nil on any non-200 status or transport failure.
  def introspect(token)
    response = connection.post(config.introspect_url) do |request|
      request.headers["Authorization"] = "Bearer #{token}"
      request.headers["Accept"] = "application/json"
    end

    return nil unless response.status == 200

    response.body
  rescue Faraday::Error
    nil
  end

  private

  attr_reader :config

  def connection
    timeout = config.introspection_timeout
    Faraday.new do |conn|
      conn.options.timeout = timeout
      conn.options.open_timeout = timeout
      conn.response :json, content_type: /\bjson$/
      conn.adapter Faraday.default_adapter
    end
  end
end
