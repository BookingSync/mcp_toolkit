# frozen_string_literal: true

# Optional base class for a HOST's own tools served by the authority dispatcher
# (McpToolkit::Dispatcher). A host tool MAY subclass this, or may be any object
# satisfying the duck-typed tool contract the dispatcher calls:
#
#   tool.required_permissions_scope        -> String | nil   (gem's scope gate)
#   tool.call(context:, **arguments)       -> Hash | String  (gem wraps into
#                                                              { content: [...] })
#
# The dispatcher treats the object returned by `provider.find(name)` as the tool;
# an AuthorityBase SUBCLASS satisfies the contract as CLASS methods (the class
# `.call` instantiates, runs, and error-maps a single invocation).
#
# What this base adds over hand-rolling the contract:
#   * a class DSL (`tool_name` / `description` / `input_schema` /
#     `required_permissions_scope` / `definition`) mirroring the tool-definition
#     shape `tools/list` returns;
#   * per-request accessors (`account` / `principal` / `bearer_token` /
#     `superuser?`) read from the injected Authority::Context;
#   * `ensure_resource_accessible!` to gate a superuser-only resource;
#   * error mapping — an ArgumentError (e.g. a missing required kwarg) becomes an
#     InvalidParams, any other StandardError an InternalError, while a
#     deliberately-raised McpToolkit::Protocol::Error passes through with its own
#     code.
#
# The gem NEVER references a host's API layer, serializers, or resource catalog —
# all of that lives behind the host's `#call`.
class McpToolkit::Tools::AuthorityBase
  class << self
    attr_reader :_tool_name, :_description, :_input_schema

    def tool_name(name = nil)
      if name
        @_tool_name = name.to_s
      else
        @_tool_name || self.name.to_s.demodulize.underscore.gsub(/_tool$/, "")
      end
    end

    def description(desc = nil)
      @_description = desc if desc
      @_description
    end

    def input_schema(&block)
      @_input_schema = yield if block
      @_input_schema || { type: "object", properties: {} }
    end

    # OAuth-style scope (`<app>__<action>`) a token must carry to call this tool,
    # enforced by the dispatcher before the tool runs. Defaults to nil (no scope
    # required). NOT inherited — a subclass that doesn't declare its own scope is
    # unscoped, even if an ancestor declared one.
    def required_permissions_scope(scope = nil)
      @_required_permissions_scope = scope.to_s if scope
      @_required_permissions_scope
    end

    def definition
      {
        name: tool_name,
        description: _description,
        inputSchema: _input_schema || { type: "object", properties: {} }
      }
    end

    # The dispatcher's entry point: build an instance bound to this request's
    # context and run it, mapping tool-level errors to protocol errors.
    def call(context:, **arguments)
      new(context:).execute(**arguments)
    end
  end

  attr_reader :context

  def initialize(context:)
    @context = context
  end

  def account
    context.account
  end

  def principal
    context.principal
  end

  def bearer_token
    context.bearer_token
  end

  # Whether the caller is a superuser, per the Context (which duck-types it off
  # the principal). Used to gate resources/tools that expose cross-tenant data.
  def superuser?
    context.superuser?
  end

  # Guards a resource flagged `superusers_only?`: a non-superuser caller is
  # refused. No-op for unrestricted resources.
  def ensure_resource_accessible!(resource)
    return unless resource.superusers_only?
    return if superuser?

    raise McpToolkit::Protocol::InvalidRequest, "#{resource.name} is restricted to superuser (user-scoped) MCP tokens"
  end

  # Runs the tool's business logic (the subclass's `#call`) with error mapping.
  # Arrives with symbol-keyed arguments from the dispatcher.
  def execute(**arguments)
    call(**arguments)
  rescue McpToolkit::Protocol::Error
    # A deliberately-raised protocol error carries its own JSON-RPC code
    # (e.g. InvalidParams); let it bubble untouched so the client sees it.
    raise
  rescue ArgumentError => e
    raise McpToolkit::Protocol::InvalidParams, e.message
  rescue StandardError => e
    # An UNEXPECTED error's message may carry SQL, internal class names, or a
    # hostname — it must not reach the caller (the dispatcher relays a
    # Protocol::Error's message verbatim). Log the detail; return a generic error.
    McpToolkit.config.logger&.error("MCP tool #{self.class} error: #{e.message}\n#{e.backtrace&.join("\n")}")
    raise McpToolkit::Protocol::InternalError, "Internal error"
  end

  # The subclass implements its business logic here, receiving the tool arguments
  # as keywords and returning a Hash or String.
  def call(**_arguments)
    raise NotImplementedError, "#{self.class} must implement #call"
  end
end
