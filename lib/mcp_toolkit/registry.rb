# frozen_string_literal: true

# Central registry of read-only resources exposed via the MCP server. Resources
# are registered at boot (in a `to_prepare` initializer) and consumed by the
# generic `resources` / `resource_schema` / `get` / `list` tools.
#
# Instances are addressable so tests (and, in principle, multiple mounted
# servers) don't collide; the app-facing convenience is `McpToolkit.registry`,
# which returns the process-wide instance.
class McpToolkit::Registry
  class UnknownResource < StandardError; end

  def initialize
    @resources = {}
    @default_required_permissions_scope = nil
    @resource_extension = nil
    @resource_finalizer = nil
  end

  # A Module MIXED INTO every Resource before its registration block runs, so a host
  # can add its OWN declaration DSL (its "extras") on top of the gem's built-in
  # `model` / `scope` / `serializer` / `filterable` / `superusers_only!` / `note` /
  # `filter`. The host method typically stores into the generic `Resource#extra`
  # bag; the `resource_finalizer` reads it back. nil (the default) mixes in nothing,
  # so a host with no extras is unaffected. Set ONCE in `configure` (not per reload),
  # since `reset!` preserves it.
  #
  #   McpToolkit.registry.resource_extension = MyApp::ResourceExtension  # adds `dependencies`
  #
  # @return [Module, nil]
  attr_accessor :resource_extension

  # A callable run against each Resource AFTER its registration block, so a host can
  # derive gem-native fields from its declared extras — e.g. build a `serializer`
  # from the `model` + declared `dependencies`, or a lazy `filterable`. `->(resource)`.
  # nil (the default) is a no-op. This is the hook that lets a host avoid a parallel
  # registration system: it declares resources DIRECTLY against the gem registry and
  # fills the derived pieces here. Set ONCE in `configure`; preserved across `reset!`.
  #
  # @return [#call, nil]
  attr_accessor :resource_finalizer

  # Registry-wide DEFAULT required scope, so a satellite declares its scope ONCE
  # for every resource instead of repeating it per resource:
  #
  #   McpToolkit.registry.default_required_permissions_scope "notifications__read"
  #
  # A resource's own `required_permissions_scope` overrides this. Default nil = no
  # scope required unless a resource declares its own. Read with no arg.
  #
  # Declared in the satellite's `configure` block (NOT inside `to_prepare`), so it
  # survives `reset!` and stays set across dev reloads.
  def default_required_permissions_scope(scope = nil)
    @default_required_permissions_scope = scope if scope
    @default_required_permissions_scope
  end

  def register(name, &)
    resource = McpToolkit::Resource.new(name)
    resource.extend(@resource_extension) if @resource_extension
    resource.instance_eval(&)
    @resource_finalizer&.call(resource)
    @resources[name.to_s] = resource
  end

  # The scope a token must carry to reach `resource` via the generic tools: the
  # resource's own declared scope, else the registry default, else nil (no check).
  def required_scope_for(resource)
    resource.effective_required_permissions_scope(@default_required_permissions_scope)
  end

  def fetch(name)
    find(name) or raise(UnknownResource, McpToolkit::UnknownResourceMessage.new(name, resource_names).build)
  end

  def find(name)
    @resources[name.to_s]
  end

  def resources
    @resources.values
  end

  def resource_names
    @resources.keys
  end

  # Clears registered resources for a dev reload (the satellite re-declares them
  # in `to_prepare`). The `default_required_permissions_scope`, `resource_extension`
  # and `resource_finalizer` are PRESERVED, since they're declared once in
  # `configure` rather than per-reload.
  def reset!
    @resources = {}
  end
end
