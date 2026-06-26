# frozen_string_literal: true

# The toolkit was used before it was configured, or a required piece of
# configuration is missing for the operation being attempted.
class McpToolkit::Errors::ConfigurationError < McpToolkit::Errors::Base; end
