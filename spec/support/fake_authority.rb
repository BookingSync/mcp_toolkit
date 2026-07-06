# frozen_string_literal: true

# Reusable, vendor-neutral doubles for the AUTHORITY path specs. They stand in for
# a host's token model, account, tool and tool-provider WITHOUT any api_v3 / app
# knowledge — the whole point of the api-agnostic seam.

# A resolved tenant. The gem only reads `#id` (forwarded upstream as the account
# selector; embedded in a usage event).
FakeAccount = Struct.new(:id)

# A duck-typed principal (the "token"): the methods the authority path calls.
#   #authorized_for_scope?(scope) — the dispatcher's per-tool scope gate
#   #default_account              — the account when a caller pins none
#   #authorize_account(id)        — resolve a pinned account id (nil = unauthorized)
#   #superuser?                   — surfaced via Authority::Context#superuser?
class FakePrincipal
  attr_reader :id, :scopes

  def initialize(id: 1, scopes: [], default_account: nil, accounts: [], superuser: false)
    @id = id
    @scopes = Array(scopes).map(&:to_s)
    @default_account = default_account
    # Keyed by String so a header/meta/arg candidate (any of which may arrive as a
    # string) resolves regardless of the caller's type.
    @accounts = Array(accounts).to_h { |account| [account.id.to_s, account] }
    @superuser = superuser
  end

  def authorized_for_scope?(scope)
    return true if scope.to_s.empty?

    scopes.include?(scope.to_s)
  end

  attr_reader :default_account

  def authorize_account(candidate)
    return nil if candidate.to_s.empty?

    @accounts[candidate.to_s]
  end

  def superuser?
    @superuser
  end
end

# A tool satisfying the gem's duck-typed contract as an INSTANCE (the dispatcher
# calls `#required_permissions_scope` + `#call(context:, **arguments)` on whatever
# `provider.find` returns). Records every call for assertions. `result` may be a
# proc (receiving the context + arguments), a String, or a Hash.
class FakeTool
  attr_reader :calls

  def initialize(scope: nil, result: { ok: true }, &block)
    @scope = scope
    @result = block || result
    @calls = []
  end

  def required_permissions_scope
    @scope
  end

  def call(context:, **arguments)
    @calls << { context:, arguments: }
    @result.respond_to?(:call) ? @result.call(context, arguments) : @result
  end
end

# A host tool catalog satisfying the provider contract:
#   #tool_definitions(context) -> [{ name:, description:, inputSchema: }]
#   #find(name)                -> a tool, or nil
# `definitions_for` may filter by context (e.g. hide superuser-only tools).
class FakeToolProvider
  def initialize(tools: {}, definitions: nil, &definitions_for)
    @tools = tools # name => FakeTool
    @definitions = definitions
    @definitions_for = definitions_for
  end

  def tool_definitions(context)
    return @definitions_for.call(context) if @definitions_for
    return @definitions if @definitions

    @tools.keys.map { |name| { name:, description: "#{name} tool", inputSchema: { type: "object" } } }
  end

  def find(name)
    @tools[name]
  end
end
