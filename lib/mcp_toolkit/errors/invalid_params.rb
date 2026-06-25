# frozen_string_literal: true

# The arguments to a tool were invalid (missing id, unknown resource, bad
# account selection, etc.).
class McpToolkit::Errors::InvalidParams < McpToolkit::Errors::Base; end
