# frozen_string_literal: true

# Registry of upstream MCP servers a GATEWAY app aggregates and proxies to.
#
# Each upstream has a `key` (the tool-name namespace prefix — its tools are
# surfaced as `<key>__<tool>`) and a `url` (the upstream's MCP HTTP endpoint).
# Upstreams are registered at boot (typically from ENV); an upstream whose url is
# blank is never registered, so an unconfigured environment behaves exactly like
# a gateway with no upstreams.
#
# Unlike a global module singleton, this is a PER-CONFIG instance (like
# `config.registry`): each `McpToolkit::Configuration` carries its own, exposed as
# `config.upstreams`. That gives test isolation for free (a fresh config resets
# it) and matches the gem's per-config convention. Register via the config sugar
# `config.register_upstream(key:, url:)` or directly on `config.upstreams`.
class McpToolkit::Gateway::UpstreamRegistry
  # Separates an app key from a tool name in an aggregated tool name. A double
  # underscore so it doesn't collide with single underscores in bare tool names
  # (e.g. "list_items"); it also matches the gem's `<app>__<action>` scope
  # separator.
  NAMESPACE_SEPARATOR = "__"

  # `public_tool_list` is the gateway-cache contract: an upstream's `tools/list`
  # MUST be caller-INDEPENDENT (the same public tools for every valid token; scope
  # is enforced only when a tool is CALLED). That invariant is what lets the
  # Aggregator share one cache entry per upstream across all callers. An upstream
  # that filters its list by the caller's privilege (e.g. hides superuser-only
  # tools) breaks it and MUST register `public_tool_list: false`, which opts it out
  # of the shared cache so a privileged caller's list can't leak to an
  # unprivileged one. Default true — the overwhelming common case.
  Upstream = Data.define(:key, :url, :public_tool_list) do
    def initialize(key:, url:, public_tool_list: true)
      super
    end

    def name_for(tool_name)
      "#{key}#{NAMESPACE_SEPARATOR}#{tool_name}"
    end
  end

  def initialize
    @registered = {}
  end

  # Registers an upstream by key. A blank url is ignored, so callers can pass an
  # ENV lookup directly without guarding it. Pass `public_tool_list: false` for an
  # upstream whose tool list varies by caller privilege, opting it out of the
  # shared list cache (see the Upstream contract above).
  def register(key:, url:, public_tool_list: true)
    return if url.blank?

    @registered[key.to_s] = Upstream.new(key: key.to_s, url:, public_tool_list:)
  end

  # Clears every registered upstream.
  def reset!
    @registered = {}
  end

  # All registered upstreams (insertion order).
  def all
    @registered.values
  end

  # The registered upstream for a key, or nil.
  def find(key)
    @registered[key.to_s]
  end

  # `<app>__<tool>` -> [app_key, bare_tool_name] for a registered upstream; nil
  # for an un-namespaced name or an unknown/unregistered key.
  def split_tool_name(tool_name)
    prefix, separator, rest = tool_name.to_s.partition(NAMESPACE_SEPARATOR)
    return nil if separator.empty? || rest.empty?
    return nil unless find(prefix)

    [prefix, rest]
  end
end
