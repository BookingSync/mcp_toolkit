# frozen_string_literal: true

require "concurrent"

# Aggregates the tool lists of all configured upstream MCP servers for a
# gateway's `tools/list`, namespacing each tool as `<app>__<tool>`.
#
# Per upstream the namespaced list is cached in `config.cache_store`
# (`config.upstream_list_ttl`, default 15 min) and bustable via `flush!` /
# `flush!(key)`. On a cache miss the live pull runs per-upstream (one HTTP call
# each); a failing/timeout upstream is omitted + logged, never breaking the list.
#
# Why the cache is safe to share globally: an upstream's `tools/list` is
# token-INDEPENDENT — it returns the same public tool definitions to every valid
# caller and enforces scope only when a tool is CALLED (per-call authorization is
# the upstream's job). So one caller's pull is a correct answer for all callers.
#
# Only a NON-EMPTY pull is ever cached. An empty or failed pull is almost always a
# transient upstream hiccup (timeout, a session/handshake blip, a degenerate 200);
# caching it would freeze a whole app's tools out of `tools/list` for the full TTL
# for EVERY caller (a poisoned global cache), which is exactly the failure this
# guards against. A stale empty already in the cache is treated as a miss and
# re-pulled, so the aggregate self-heals as soon as the upstream returns tools.
#
# Concurrency: upstreams are pulled CONCURRENTLY via concurrent-ruby futures. When
# running inside Rails, each future is wrapped in `Rails.application.executor` so
# it participates in the framework's per-request lifecycle (reloading, query
# cache, connection checkout); a non-Rails host runs plain futures. Output order
# follows the registry order.
class McpToolkit::Gateway::Aggregator
  CACHE_KEY_PREFIX = "mcp_toolkit:gateway:tools:"

  def initialize(config: McpToolkit.config)
    @config = config
  end

  # Namespaced tool definitions across all configured upstreams. `bearer_token`
  # is used only on a cache miss, so the upstream can authenticate the list
  # request the same way it would a call. Upstreams are fetched concurrently;
  # output order follows the registry order.
  def tool_definitions(bearer_token: nil)
    futures = config.upstreams.all.map do |upstream|
      Concurrent::Promises.future do
        within_executor { cached_or_live_definitions(upstream, bearer_token:) }
      end
    end

    futures.flat_map(&:value!)
  end

  def flush!(key = nil)
    if key
      cache.delete(cache_key(key))
    else
      config.upstreams.all.each { |upstream| cache.delete(cache_key(upstream.key)) }
    end
  end

  private

  attr_reader :config

  # Runs the block inside the Rails executor when a BOOTED Rails app is present
  # (so a future participates in the request lifecycle: reloading, query cache,
  # connection checkout), or plainly otherwise. Guards for `Rails` being defined
  # but not booted (e.g. `rails/version` required without an initialized app), in
  # which case `Rails.application` is nil and we run the block directly.
  def within_executor(&)
    if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      Rails.application.executor.wrap(&)
    else
      yield
    end
  end

  def cached_or_live_definitions(upstream, bearer_token:)
    cached = cache.read(cache_key(upstream.key))
    # `present?` treats both a nil miss AND a stale empty list as "no cache", so a
    # previously poisoned empty entry is re-pulled instead of served.
    return cached if cached.present?

    definitions = live_definitions(upstream, bearer_token:)
    # Only persist a real, non-empty list; never cache an empty/degraded pull.
    cache.write(cache_key(upstream.key), definitions, expires_in: config.upstream_list_ttl) if definitions.present?
    definitions
  rescue McpToolkit::Gateway::Client::Error => e
    # Degrade gracefully: omit this upstream's tools, don't cache the failure.
    config.logger&.error("MCP upstream #{upstream.key} tools/list failed, omitting: #{e.message}")
    []
  end

  def live_definitions(upstream, bearer_token:)
    client = McpToolkit::Gateway::Client.new(upstream:, bearer_token:, config:)
    client.tools_list.map do |definition|
      namespaced(upstream, definition)
    end
  end

  # Re-keys an upstream tool definition into the gateway's aggregate namespace.
  def namespaced(upstream, definition)
    definition = definition.dup
    definition["name"] = upstream.name_for(definition["name"])
    definition
  end

  def cache
    config.cache_store
  end

  def cache_key(key)
    "#{CACHE_KEY_PREFIX}#{key}"
  end
end
