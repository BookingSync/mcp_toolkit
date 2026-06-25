# frozen_string_literal: true

require "zeitwerk"

# Stdlib + external gems the toolkit's own code calls. Zeitwerk autoloads the
# gem's `lib/mcp_toolkit/**` tree, but NOT these third-party / stdlib constants,
# so they are required here once (centralized) rather than scattered across the
# subfiles that happen to touch them:
#
#   json          - JSON.parse / JSON.generate (introspection parse, tools, transport)
#   digest        - Digest::SHA256 (introspection cache key)
#   time          - Time.iso8601 / Time.parse (introspection expiry parsing)
#   securerandom  - SecureRandom.uuid (Session ids)
#   mcp           - the official MCP SDK (Server wraps it; Tools::Base subclasses MCP::Tool)
#   active_support/concern - Transport::ControllerMethods is an includable concern
#   active_support/cache   - the default MemoryStore cache_store
#
# `faraday` is the one exception: it is required alongside its sole owner,
# Auth::AuthorityServerClient, which is the only object that builds an HTTP
# connection.
require "json"
require "digest"
require "time"
require "securerandom"
require "mcp"
require "active_support/concern"
require "active_support/cache"

# External dependencies (NOT autoloaded by Zeitwerk — only the gem's own tree is).
# ActiveSupport's specific core extensions are required up front (rather than full
# Rails) so the gem works in any host. Each line below earns its place; they were
# audited against actual usage:
#
#   object/blank             - blank? / present? / presence (used throughout)
#   hash/keys                - deep_symbolize_keys (ListExecutor#initialize)
#   array/wrap               - Array.wrap (Transport::ControllerMethods)
#   enumerable               - compact_blank (ListExecutor#apply_ids)
#   time/conversions         - Time#iso8601 (Serializer::Base timestamps;
#                              Time.zone.parse in ListExecutor)
#   date_time/conversions    - DateTime#iso8601 (token expires_at may be a DateTime)
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/array/wrap"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/date_time/conversions"

# The version constant is needed eagerly by the gemspec (before the loader is set
# up), so it stays an explicit require rather than an autoload.
require_relative "mcp_toolkit/version"

loader = Zeitwerk::Loader.for_gem
# `version.rb` is loaded manually above; let Zeitwerk ignore it so it doesn't try
# to manage the already-defined constant.
loader.ignore("#{__dir__}/mcp_toolkit/version.rb")
loader.setup

# The toolkit for building account-scoped, read-only MCP servers on top of the
# official `mcp` gem. See README.md for the satellite + authority quickstarts.
#
# Entry points:
#   McpToolkit.configure { |c| ... }  # set up the server
#   McpToolkit.config                 # the active Configuration
#   McpToolkit.registry               # the active config's resource registry
#
# `MCPToolkit` is provided as an alias for the same module.
module McpToolkit
  # The toolkit's own base error (kept distinct from tool-level Errors::*).
  class Error < StandardError; end

  # Yields the active configuration for mutation, returning it.
  #
  #   McpToolkit.configure do |c|
  #     c.server_name = "my-app-mcp"
  #     c.central_app_url = ENV.fetch("MCP_CENTRAL_APP_URL")
  #     c.required_application = "my_app"
  #   end
  def self.configure
    yield(config) if block_given?
    config
  end

  # The active Configuration (created on first access).
  def self.config
    @config ||= Configuration.new
  end

  # The active config's resource registry. Register resources against this in a
  # boot initializer.
  def self.registry
    config.registry
  end

  # Replaces the active configuration with a fresh default. Primarily for tests.
  def self.reset_config!
    @config = Configuration.new
  end
end

# Karol's requested entry-point spelling. `MCPToolkit.configure { ... }` and
# `MCPToolkit.config` work identically to `McpToolkit.*`.
MCPToolkit = McpToolkit unless defined?(MCPToolkit)
