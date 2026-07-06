# frozen_string_literal: true

# Shared base for the four GENERIC, Registry-backed authority tools
# (McpToolkit::Authority::Tools::{Resources,ResourceSchema,Get,List}) served
# through McpToolkit::Authority::RegistryToolProvider on the hand-rolled
# authority dispatch path.
#
# Unlike the satellite tools (McpToolkit::Tools::*, which subclass the SDK's
# MCP::Tool, self-authenticate, and return an MCP::Tool::Response), these are
# plain objects satisfying the dispatcher's duck-typed tool contract:
#
#   tool.required_permissions_scope  -> nil   (see below — no STATIC scope)
#   tool.call(context:, **arguments) -> Hash  (the dispatcher wraps it into
#                                              { content: [{ type: "text", ... }] })
#
# The scope a caller needs is DYNAMIC — it depends on which `resource` argument
# was passed — so these tools declare no static scope and instead enforce the
# resolved resource's `required_scope_for` INSIDE #call (see #ensure_scope!).
# The `context` (McpToolkit::Authority::Context) supplies the resolved account,
# the principal, and the derived superuser flag.
#
# The tools reuse the existing executors / schema builder UNCHANGED; this base
# only holds the resolution + gating every one of them repeats: resolve the
# resource descriptor, gate a superuser-only resource, gate the per-resource
# scope, and (for get/list) require a selected account.
class McpToolkit::Authority::Tools::Base
  class << self
    attr_reader :_description, :_input_schema

    def tool_name(name = nil)
      @_tool_name = name.to_s if name
      @_tool_name
    end

    def description(text = nil)
      @_description = text if text
      @_description
    end

    def input_schema(schema = nil)
      @_input_schema = schema if schema
      @_input_schema || { type: "object", properties: {} }
    end

    # The static tool definition returned by the provider's `tool_definitions`
    # (part of `tools/list`). Generic and context-independent.
    def definition
      { name: tool_name, description: _description, inputSchema: input_schema }
    end
  end

  attr_reader :config

  def initialize(config:)
    @config = config
  end

  # The dispatcher's central scope gate reads this; nil = no STATIC scope. The
  # real, per-resource scope is enforced dynamically in #ensure_scope! (the scope
  # depends on the `resource` argument, unknown until #call).
  def required_permissions_scope
    nil
  end

  private

  def registry
    config.registry
  end

  # Resolves the `resource` argument to a registered descriptor, raising the
  # protocol InvalidParams (=> JSON-RPC -32602) for a blank or unknown name so the
  # dispatcher renders a clean top-level error.
  def resolve_descriptor(name)
    raise McpToolkit::Protocol::InvalidParams, "resource is required" if name.to_s.strip.empty?

    registry.fetch(name)
  rescue McpToolkit::Registry::UnknownResource => e
    raise McpToolkit::Protocol::InvalidParams, e.message
  end

  # Refuses a superuser-only resource for a non-superuser caller (get / list /
  # resource_schema). `resources` HIDES such resources instead — see that tool.
  def ensure_resource_accessible!(descriptor, context)
    return unless descriptor.superusers_only?
    return if context.superuser?

    raise McpToolkit::Protocol::InvalidRequest,
          "#{descriptor.name} is restricted to superuser (user-scoped) MCP tokens"
  end

  # Enforces the resource's effective required scope against the principal. Blank
  # scope => no check. Mirrors the dispatcher's central gate error shape
  # (InvalidRequest), keeping scope refusals byte-consistent across host tools.
  def ensure_scope!(descriptor, context)
    required = registry.required_scope_for(descriptor)
    return if required.to_s.empty?
    return if context.principal&.authorized_for_scope?(required)

    raise McpToolkit::Protocol::InvalidRequest, "This token lacks the #{required.inspect} scope"
  end

  # get / list read tenant data, so they REQUIRE a resolved account: a superuser
  # token that selected none would otherwise reach `scope.call(nil)` and leak
  # across tenants. resource_schema / resources (shape only) do not call this.
  def ensure_account!(context)
    return if context.account

    raise McpToolkit::Protocol::InvalidParams,
          "an account must be selected (pass account_id) to read this resource"
  end

  # Runs an executor, translating a data-layer McpToolkit::Errors::InvalidParams
  # (bad id, unknown filter/field key, ...) into the protocol InvalidParams the
  # dispatcher renders as JSON-RPC -32602 (rather than letting it fall through to
  # the dispatcher's generic -32603 internal-error mapping).
  def run_executor
    yield
  rescue McpToolkit::Errors::InvalidParams => e
    raise McpToolkit::Protocol::InvalidParams, e.message
  end
end
