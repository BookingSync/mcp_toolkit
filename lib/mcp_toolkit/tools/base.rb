# frozen_string_literal: true

# Base class for the generic MCP tools. Subclasses an official-SDK `MCP::Tool`,
# so `name`/`description`/`input_schema` and the `call` contract are the gem's.
# This base adds the shared concern every tool needs: authenticating +
# scope-resolving the caller (via McpToolkit::Auth::Authenticator) before
# running, and turning tool-level errors into `isError: true` MCP results
# (rather than letting them become JSON-RPC protocol errors).
#
# The bearer token, JSON-RPC `_meta`, and the account-id header are threaded in
# through `server_context` (set per-request by the controller). The active
# McpToolkit config is also threaded in as `server_context[:mcp_config]` so a
# process can, in principle, host more than one configured server; it falls back
# to `McpToolkit.config`.
class McpToolkit::Tools::Base < MCP::Tool
  # Runs `block` with an authenticated, scoped context, serializing any
  # McpToolkit::Errors into a clean text tool error.
  #
  # The resolved `scope_root` is yielded — it is the tools' serializer `scope`
  # AND the root every query is scoped through.
  #
  # `account_id` is the superuser account selector arriving as a tool
  # argument (the gem passes tool args as kwargs, not via server_context),
  # threaded here so it joins `_meta` / the header in the resolution order.
  #
  # `required_scope` is the explicitly-declared scope a token must carry (the
  # caller resolves it from the resource — see Registry#required_scope_for).
  # Empty/nil => no scope check (authorized_for_scope? treats "" as a pass).
  def self.with_account(server_context, account_id: nil, required_scope: nil, resource: nil)
    config = config_from(server_context)
    context = McpToolkit::Auth::Authenticator.call(
      token: server_context[:bearer_token],
      meta: meta_from(server_context),
      arguments: { "account_id" => account_id }.compact,
      header_account_id: server_context[:header_account_id],
      config:
    )

    unless context.introspection.authorized_for_scope?(required_scope)
      return error_response("Unauthorized: token lacks the #{required_scope.inspect} scope")
    end

    superuser_refusal = superuser_only_refusal(resource, context.introspection)
    return superuser_refusal if superuser_refusal

    text_response(yield(context.scope_root))
  rescue McpToolkit::Errors::Unauthorized => e
    error_response("Unauthorized: #{e.message}")
  rescue McpToolkit::Errors::InvalidParams => e
    error_response("Invalid request: #{e.message}")
  end

  # Authenticates the token (valid + the explicitly-declared `required_scope`)
  # WITHOUT requiring an account selection. Used by the schema-discovery tools,
  # which reveal shape, not tenant data, so a superuser shouldn't have to pin an
  # account just to discover what exists. Empty/nil `required_scope` => no scope
  # check.
  def self.with_authentication(server_context, required_scope: nil, resource: nil)
    config = config_from(server_context)
    introspection = McpToolkit::Auth::Introspection.call(server_context[:bearer_token], config:)
    return error_response("Unauthorized: invalid or expired token") unless introspection.valid?

    unless introspection.authorized_for_scope?(required_scope)
      return error_response("Unauthorized: token lacks the #{required_scope.inspect} scope")
    end

    superuser_refusal = superuser_only_refusal(resource, introspection)
    return superuser_refusal if superuser_refusal

    # Yields the introspection so a discovery tool (`resources`) can HIDE
    # superuser-only resources from a non-superuser caller (get/list/resource_schema
    # instead pass `resource:` above to REFUSE a specific one).
    text_response(yield(introspection))
  rescue McpToolkit::Errors::InvalidParams => e
    error_response("Invalid request: #{e.message}")
  end

  # Refuses a superuser-only resource for a non-superuser caller (get / list /
  # resource_schema); nil = allowed. Mirrors the authority path's
  # `ensure_resource_accessible!`. `resources` HIDES such resources instead of
  # refusing — it filters on `introspection.superuser?` directly.
  def self.superuser_only_refusal(resource, introspection)
    return nil unless resource&.superusers_only?
    return nil if introspection.superuser?

    error_response("Unauthorized: #{resource.name} is restricted to superuser (user-scoped) MCP tokens")
  end

  def self.text_response(payload)
    text = payload.is_a?(String) ? payload : JSON.generate(payload)
    MCP::Tool::Response.new([{ type: "text", text: }])
  end

  def self.error_response(message)
    MCP::Tool::Response.new([{ type: "text", text: message }], error: true)
  end

  # The gem nests the request `_meta` under server_context[:_meta].
  def self.meta_from(server_context)
    server_context[:_meta] || {}
  end

  def self.config_from(server_context)
    server_context[:mcp_config] || McpToolkit.config
  end

  def self.lookup_resource(name, config)
    config.registry.fetch(name)
  rescue McpToolkit::Registry::UnknownResource => e
    raise McpToolkit::Errors::InvalidParams, e.message
  end

  # Validates the `resource` argument is present and resolves its descriptor,
  # raising InvalidParams (=> clean tool error) for a blank or unknown resource.
  def self.resolve_descriptor(name, config)
    raise McpToolkit::Errors::InvalidParams, "resource is required" if name.to_s.strip.empty?

    lookup_resource(name, config)
  end
end
