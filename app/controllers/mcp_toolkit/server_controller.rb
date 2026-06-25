# frozen_string_literal: true

# The MCP transport controller, provided BY the gem so a satellite mounting
# McpToolkit::Engine writes no controller of its own. It is the standalone
# McpToolkit::Transport::ControllerMethods concern wired into a controller.
#
# Its parent class is configurable (Doorkeeper-style) via
# `McpToolkit.config.parent_controller` (default "ActionController::Base"), so a
# satellite can keep ActionController::Base (NOT ::API) for its logstasher
# `helper_method` hook:
#
#   c.parent_controller = "ApplicationController"
#
# Lives under the gem's app/controllers (an engine path), so it's loaded by Rails'
# autoloader via the engine — never by the gem's own Zeitwerk loader, which only
# manages lib/. Non-Rails consumers never see it.
class McpToolkit::ServerController < McpToolkit.config.parent_controller.constantize
  include McpToolkit::Transport::ControllerMethods
end
