# frozen_string_literal: true

require "zeitwerk"

# Stdlib + external gems the toolkit's own code calls. Zeitwerk autoloads the
# gem's `lib/mcp_toolkit/**` tree, but NOT these third-party / stdlib constants,
# so they are required here once (centralized) rather than scattered across the
# subfiles that happen to touch them:
#
#   json          - JSON.parse / JSON.generate (introspection parse, tools, transport)
#   digest        - Digest::SHA256 (introspection cache key; OAuth bridge PKCE digest)
#   time          - Time.iso8601 / Time.parse (introspection expiry parsing)
#   securerandom  - SecureRandom.uuid (Session ids; OAuth bridge codes/client ids)
#   uri           - URI.parse / encode_www_form (OAuth bridge redirect construction)
#   mcp           - the official MCP SDK (Server wraps it; Tools::Base subclasses MCP::Tool)
#   active_support/concern - Transport::ControllerMethods is an includable concern
#   active_support/cache   - the default MemoryStore cache_store
#   active_support/security_utils - constant-time compare (OAuth bridge PKCE)
#
# Two third-party libs are the exception to the centralize-here rule: each is
# required alongside its owner file rather than up front.
#   faraday    - the HTTP client, required by the objects that build a connection
#                (Auth::AuthorityServerClient and Gateway::Client).
#   concurrent - concurrent-ruby's futures, required by its sole owner
#                Gateway::Aggregator (which pulls upstreams in parallel).
require "json"
require "digest"
require "time"
require "securerandom"
require "uri"
require "mcp"
require "active_support/concern"
require "active_support/cache"
require "active_support/security_utils"

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
#   string/inflections       - String#pluralize (ResourceSchema resolves a link's
#                              singular name to the plural registered resource name)
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/keys"
require "active_support/core_ext/array/wrap"
require "active_support/core_ext/enumerable"
require "active_support/core_ext/time/conversions"
require "active_support/core_ext/date_time/conversions"
require "active_support/core_ext/string/inflections"

# The version constant is needed eagerly by the gemspec (before the loader is set
# up), so it stays an explicit require rather than an autoload.
require_relative "mcp_toolkit/version"

loader = Zeitwerk::Loader.for_gem
# `version.rb` is loaded manually above; let Zeitwerk ignore it so it doesn't try
# to manage the already-defined constant.
loader.ignore("#{__dir__}/mcp_toolkit/version.rb")
# `engine.rb` subclasses ::Rails::Engine, which is absent in a non-Rails host (and
# in the gem's own unit suite). Keep it out of the autoloadable set and require it
# explicitly below only when Rails is present. The gem-internal controller lives
# under `app/controllers` (outside this lib-rooted loader), so it needs no ignore;
# it is loaded by Rails' autoloader via the engine when mounted.
loader.ignore("#{__dir__}/mcp_toolkit/engine.rb")
# `engine_controllers.rb` reopens `McpToolkit` to add the lazy `parent_controller`
# builder + `const_missing` (it defines module methods, not a file-named
# constant), so it is required explicitly below rather than autoloaded.
loader.ignore("#{__dir__}/mcp_toolkit/engine_controllers.rb")
loader.setup

# The lazy `parent_controller` builder (McpToolkit.build_engine_controllers! /
# reset_engine_controllers! / const_missing). Required unconditionally (it names no
# Rails constant at load time); it only builds controllers when one is referenced,
# which happens only under Rails.
require_relative "mcp_toolkit/engine_controllers"

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
  #     c.registry.default_required_permissions_scope "my_app__read"
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

# The mountable engine is ADDITIVE and Rails-only: a satellite can either mount
# `McpToolkit::Engine` (engine + gem controller) OR keep including
# `McpToolkit::Transport::ControllerMethods` in its own controller. Loaded only
# when Rails::Engine is present (it was ignored by the loader above).
require_relative "mcp_toolkit/engine" if defined?(Rails::Engine)
