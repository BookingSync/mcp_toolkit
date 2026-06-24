# frozen_string_literal: true

require "mcp"
require "json"

module McpToolkit
  module Tools
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
    #
    # Extracted from bsa-notifications' `McpServer::Tools::Base`.
    class Base < MCP::Tool
      class << self
        # The OAuth-style action this tool requires, combined with the configured
        # `required_application` into the `<app>_<action>` scope a token must carry
        # (e.g. `notifications_read`). Defaults to `:read`; inherited by subclasses.
        # A write tool would declare `scope_action :write`.
        def scope_action(action = nil)
          @scope_action = action.to_sym if action
          @scope_action || :read
        end

        # Runs `block` with an authenticated, scoped context, serializing any
        # McpToolkit::Errors into a clean text tool error.
        #
        # The resolved `scope_root` is yielded — it is the tools' serializer `scope`
        # AND the root every query is scoped through.
        #
        # `account_id` is the superuser account selector arriving as a tool
        # argument (the gem passes tool args as kwargs, not via server_context),
        # threaded here so it joins `_meta` / the header in the resolution order.
        def with_account(server_context, account_id: nil)
          config = config_from(server_context)
          context = McpToolkit::Auth::Authenticator.call(
            token: server_context[:bearer_token],
            meta: meta_from(server_context),
            arguments: { "account_id" => account_id }.compact,
            header_account_id: server_context[:header_account_id],
            config:
          )

          required_scope = "#{config.required_application}_#{scope_action}"
          unless context.introspection.authorized_for_scope?(required_scope)
            return error_response("Unauthorized: token lacks the #{required_scope.inspect} scope")
          end

          text_response(yield(context.scope_root))
        rescue McpToolkit::Errors::Unauthorized => e
          error_response("Unauthorized: #{e.message}")
        rescue McpToolkit::Errors::InvalidParams => e
          error_response("Invalid request: #{e.message}")
        end

        # Authenticates the token (valid + required-application scope) WITHOUT
        # requiring an account selection. Used by the schema-discovery tools, which
        # reveal shape, not tenant data, so a superuser shouldn't have to pin an
        # account just to discover what exists.
        def with_authentication(server_context)
          config = config_from(server_context)
          introspection = McpToolkit::Auth::Introspection.call(server_context[:bearer_token], config:)
          return error_response("Unauthorized: invalid or expired token") unless introspection.valid?

          unless introspection.authorized_for_application?(config.required_application)
            return error_response(
              "Unauthorized: token is not authorized for the #{config.required_application.inspect} application"
            )
          end

          required_scope = "#{config.required_application}_#{scope_action}"
          unless introspection.authorized_for_scope?(required_scope)
            return error_response("Unauthorized: token lacks the #{required_scope.inspect} scope")
          end

          text_response(yield)
        rescue McpToolkit::Errors::InvalidParams => e
          error_response("Invalid request: #{e.message}")
        end

        def text_response(payload)
          text = payload.is_a?(String) ? payload : JSON.generate(payload)
          MCP::Tool::Response.new([{ type: "text", text: }])
        end

        def error_response(message)
          MCP::Tool::Response.new([{ type: "text", text: message }], error: true)
        end

        # The gem nests the request `_meta` under server_context[:_meta].
        def meta_from(server_context)
          server_context[:_meta] || {}
        end

        def config_from(server_context)
          server_context[:mcp_config] || McpToolkit.config
        end

        def lookup_resource(name, config)
          config.registry.fetch(name)
        rescue McpToolkit::Registry::UnknownResource => e
          raise McpToolkit::Errors::InvalidParams, e.message
        end
      end
    end
  end
end
