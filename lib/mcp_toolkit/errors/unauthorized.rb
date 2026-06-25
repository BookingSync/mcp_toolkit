# frozen_string_literal: true

# The caller is not authenticated / authorized (token invalid, expired, lacks
# the required application scope, or no/invalid account context).
class McpToolkit::Errors::Unauthorized < McpToolkit::Errors::Base; end
