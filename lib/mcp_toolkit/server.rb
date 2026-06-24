# frozen_string_literal: true

require "mcp"

# Builds the official-SDK `MCP::Server` for this app: the JSON-RPC dispatcher
# with the toolkit's generic tools registered. The transport / session / HTTP
# layer lives in McpToolkit::Transport::ControllerMethods; this is purely the
# gem's dispatcher with tools + the per-request server_context.
#
# The official `mcp` gem is the JSON-RPC core (per the 2026-06-18 architecture
# decision: standardize on the gem, wrapped, rather than a hand-rolled protocol).
module McpToolkit::Server
  # The generic, registry-driven toolset every server gets. Apps that want
  # additional bespoke tools pass them via `extra_tools:`.
  GENERIC_TOOLS = [
    McpToolkit::Tools::Resources,
    McpToolkit::Tools::ResourceSchema,
    McpToolkit::Tools::Get,
    McpToolkit::Tools::List
  ].freeze

  module_function

  # @param server_context [Hash] per-request context threaded to tools:
  #   :bearer_token, :header_account_id, :mcp_config, and (merged in by the gem)
  #   :_meta.
  # @param config [McpToolkit::Configuration]
  # @param extra_tools [Array<Class>] additional MCP::Tool subclasses to expose.
  # @return [MCP::Server]
  def build(server_context:, config: McpToolkit.config, extra_tools: [])
    context = server_context.dup
    context[:mcp_config] ||= config

    kwargs = {
      name: config.server_name,
      version: config.server_version,
      instructions: config.server_instructions,
      tools: GENERIC_TOOLS + Array(extra_tools),
      server_context: context
    }
    if config.protocol_version
      kwargs[:configuration] =
        MCP::Configuration.new(protocol_version: config.protocol_version)
    end

    MCP::Server.new(**kwargs)
  end
end
