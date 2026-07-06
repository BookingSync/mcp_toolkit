# frozen_string_literal: true

# Raised by McpToolkit::Gateway::Proxy when a namespaced tool call targets an
# upstream key that is not registered. The GEM does NOT translate this into any
# JSON-RPC / protocol error class — the consuming dispatcher maps it to whatever
# error shape its transport speaks (e.g. a "method not found"). Kept a plain
# McpToolkit::Error so the gem stays transport-agnostic.
class McpToolkit::Gateway::UnknownUpstream < McpToolkit::Error; end
