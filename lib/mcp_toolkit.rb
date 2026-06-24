# frozen_string_literal: true

require "zeitwerk"

# ActiveSupport core extensions the toolkit relies on. Required up front (not full
# Rails) so the gem works in any host: blank?/presence, deep_symbolize_keys,
# Array.wrap, compact_blank, iso8601 on Time/DateTime.
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/array/wrap"
require "active_support/core_ext/enumerable" # compact_blank
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

  class << self
    # Yields the active configuration for mutation, returning it.
    #
    #   McpToolkit.configure do |c|
    #     c.server_name = "my-app-mcp"
    #     c.central_app_url = ENV.fetch("MCP_CENTRAL_APP_URL")
    #     c.required_application = "my_app"
    #   end
    def configure
      yield(config) if block_given?
      config
    end

    # The active Configuration (created on first access).
    def config
      @config ||= Configuration.new
    end

    # The active config's resource registry. Register resources against this in a
    # boot initializer.
    def registry
      config.registry
    end

    # Replaces the active configuration with a fresh default. Primarily for tests.
    def reset_config!
      @config = Configuration.new
    end
  end
end

# Karol's requested entry-point spelling. `MCPToolkit.configure { ... }` and
# `MCPToolkit.config` work identically to `McpToolkit.*`.
MCPToolkit = McpToolkit unless defined?(MCPToolkit)
