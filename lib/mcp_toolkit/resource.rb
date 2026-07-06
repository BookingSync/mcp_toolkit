# frozen_string_literal: true

# Descriptor for a single read-only resource exposed via the MCP server. Built
# via `McpToolkit.registry.register`; consumed by the List/Get executors and the
# resource_schema tool.
#
# The `scope_block` is the account-rooting relation: it receives the resolved
# local scope root (typically an `Account`) and MUST return a relation already
# scoped so that every row belongs to that root (directly via a foreign key, or
# transitively through an owning record). This is the single tenancy chokepoint —
# every `get`/`list` query roots on it.
#
# The `serializer` is INJECTABLE per resource: it may be a subclass of the gem's
# `McpToolkit::Serializer::Base`, or any class satisfying the serializer contract
# (`serialize_one` / `serialize_collection`) — e.g. an app's existing serializer.
class McpToolkit::Resource
  class NotConfigured < StandardError; end

  # A resource-specific ("custom") filter: a request-facing key whose value is
  # applied to the relation by an arbitrary host-supplied block, rather than the
  # generic equality/operator allowlist. The block is api-agnostic — it receives
  # the already-scoped relation and the raw request value and returns a narrowed
  # relation — so a host can express a relational or otherwise non-column filter
  # (e.g. "only rows whose associated booking is in this rental") without the gem
  # knowing anything about the query. `type`/`description` are surfaced by
  # resource_schema so a client can discover the filter.
  CustomFilter = Struct.new(:name, :type, :description, :applier, keyword_init: true)

  attr_reader :name

  def initialize(name)
    @name = name.to_s
    @model = nil
    @serializer = nil
    @scope_block = nil
    @description = nil
    @note = nil
    @superusers_only = false
    @filterable = {}
    @filterable_source = nil
    @custom_filters = {}
    @required_permissions_scope = nil
  end

  def model(klass = nil)
    @model = klass if klass
    @model
  end

  def serializer(klass = nil)
    @serializer = klass if klass
    @serializer
  end

  def scope(&block)
    @scope_block = block if block
    @scope_block
  end

  def description(text = nil)
    @description = text if text
    @description
  end

  # Free-form usage caveat surfaced by the `resources` / `resource_schema` tools,
  # e.g. to flag a resource as internal-debugging-only and not to be interpreted
  # without domain knowledge. Read with no arg. api-agnostic passthrough string.
  def note(text = nil)
    @note = text if text
    @note
  end

  # Restricts this resource to superuser (cross-tenant) callers on the AUTHORITY
  # path: an authority tool refuses `get` / `list` / `resource_schema` for a
  # non-superuser and HIDES the resource from `resources` discovery. Declared in a
  # resource's registration block:
  #
  #   McpToolkit.registry.register(:audit_events) do
  #     superusers_only!
  #     ...
  #   end
  #
  # Generic and api-agnostic — the gem never names an app concept; the caller's
  # superuser-ness is derived by the Authority::Context off the principal.
  def superusers_only!
    @superusers_only = true
  end

  # Whether this resource is restricted to superuser callers (default false).
  def superusers_only?
    @superusers_only
  end

  # Declares a resource-specific ("custom") filter: a request-facing `name` whose
  # value is applied to the already-scoped relation by the given block. Unlike the
  # `filterable` allowlist (generic equality/operator filters on a declared
  # column), a custom filter runs ARBITRARY host logic, so a host can express a
  # relational filter the gem could not derive:
  #
  #   filter :rental_id, type: :integer, description: "Only rows for this rental" do |relation, value|
  #     relation.joins(:booking).where(bookings: { rental_id: value })
  #   end
  #
  # The block receives `(relation, value)` and MUST return a relation (narrowing
  # only). `type` / `description` are metadata surfaced by `resource_schema`. The
  # value arrives from a TOP-LEVEL request param keyed by `name` (see ListExecutor),
  # applied BEFORE the allowlist `filterable` filters. api-agnostic: the gem stores
  # and calls the block without inspecting it.
  def filter(name, type:, description:, &applier)
    @custom_filters[name.to_sym] = CustomFilter.new(name: name.to_sym, type:, description:, applier:)
  end

  # Request-facing custom-filter key (symbol) => CustomFilter. Consumed by the list
  # executor (which applies each block whose key is present in the request params)
  # and by resource_schema (which surfaces each filter's type/description).
  attr_reader :custom_filters

  # The OAuth-style scope a token MUST carry to reach this resource via the
  # generic tools (e.g. "notifications__read"). Declared explicitly per resource:
  #
  #   required_permissions_scope "notifications__read"
  #
  # Default nil = no scope required for this resource (unless the registry sets a
  # default — see Registry#default_required_permissions_scope). Read with no arg.
  def required_permissions_scope(scope = nil)
    @required_permissions_scope = scope if scope
    @required_permissions_scope
  end

  # The scope actually enforced for this resource: its own declared scope if set,
  # otherwise the registry-level `default` passed in. nil = no scope required.
  def effective_required_permissions_scope(default = nil)
    @required_permissions_scope || default
  end

  # Declares the per-attribute filters this resource accepts on the `list` tool.
  # Each entry maps a REQUEST-FACING filter key to the backing DATABASE COLUMN the
  # WHERE is applied to. The mapping is what lets the consumer-facing key differ
  # from the storage column (e.g. exposing a synced foreign key under its public
  # name):
  #
  #   filterable booking_id: :synced_booking_id
  #
  # A declared key accepts both a bare equality value AND operator-based
  # conditions (`{ op:, value: }` or an array of them, ANDed) — see
  # McpToolkit::Filtering for the supported operators per column type.
  #
  # Unmapped/unknown keys are rejected by the list executor, never silently
  # dropped, so a typo surfaces as actionable feedback.
  # Accepts a Hash (merged now) OR a callable returning a Hash (resolved LAZILY on
  # first read). The lazy form lets a host derive the map from something that must
  # NOT be touched at registration/boot time — e.g. a DB-backed column list
  # (`Model.column_names`): registration typically runs inside an initializer's
  # `to_prepare`, before the database may exist (e.g. CI's `db:create`), so hitting
  # the DB there aborts boot. A callable source is invoked at most once — on the
  # first read (a tool call, when the DB is present) — then memoized.
  def filterable(mapping = nil, &block)
    source = block || mapping
    return filterable_columns if source.nil?

    if source.respond_to?(:call)
      @filterable_source = source
    else
      merge_filterable!(source)
    end
    self
  end

  # Request-facing filter keys (symbols, sorted) this resource can be filtered
  # by. Surfaced via the `resource_schema` tool.
  def filterable_keys
    filterable_columns.keys.sort
  end

  # Request-facing filter key (symbol) => backing column (symbol). Consumed by
  # the list executor to build the WHERE clause.
  def filterable_columns
    resolve_filterable_source!
    @filterable
  end

  # The account-scoped relation for this resource. Raises if misconfigured so a
  # registry mistake fails loudly rather than leaking an unscoped query.
  def resolve_relation(scope_root)
    raise NotConfigured, "resource #{name.inspect} has no scope block" unless scope
    raise NotConfigured, "resource #{name.inspect} has no model" unless model
    raise NotConfigured, "resource #{name.inspect} has no serializer" unless serializer

    scope.call(scope_root)
  end

  # Serialized attribute names (the response shape), read off the serializer's
  # declared attributes. Requires a serializer that exposes `declared_attributes`
  # (the gem's base does); resource_schema degrades gracefully otherwise.
  def attribute_names
    return [] unless serializer.respond_to?(:declared_attributes)

    serializer.declared_attributes.map(&:to_sym)
  end

  # Association descriptors (the `links` shape) read off the serializer.
  def association_descriptors
    return [] unless serializer.respond_to?(:declared_associations)

    serializer.declared_associations
  end

  private

  # Resolves a lazily-provided filterable source (a callable) exactly once — on the
  # first `filterable_columns` / `filterable_keys` read — then drops it, so later
  # reads are pure Hash access. This is what keeps a DB-derived map (e.g.
  # `Model.column_names`) out of registration/boot time.
  def resolve_filterable_source!
    return unless @filterable_source

    source = @filterable_source
    @filterable_source = nil
    merge_filterable!(source.call || {})
  end

  def merge_filterable!(mapping)
    mapping.each { |request_key, column| @filterable[request_key.to_sym] = column.to_sym }
  end
end
