# frozen_string_literal: true

# Composes several `tool_provider`s into one, so a host can serve the generic
# Registry-backed tools (McpToolkit::Authority::RegistryToolProvider) ALONGSIDE
# its own bespoke tools (e.g. a paper-trail/versions tool that doesn't fit the
# generic resource model) behind a single `config.tool_provider`.
#
# It satisfies the same duck-typed provider contract the dispatcher calls:
#   tool_definitions(context) -> the concatenation of every provider's definitions,
#                                in registration order
#   find(name)                -> the first provider (in order) that resolves the
#                                name, else nil
#
# Ordering is significant only if two providers advertise the same tool name; the
# first registered wins. A host controls precedence by argument order.
class McpToolkit::Authority::CompositeToolProvider
  def initialize(*providers)
    @providers = providers
  end

  def tool_definitions(context)
    @providers.flat_map { |provider| provider.tool_definitions(context) }
  end

  def find(name)
    @providers.each do |provider|
      tool = provider.find(name)
      return tool if tool
    end
    nil
  end
end
