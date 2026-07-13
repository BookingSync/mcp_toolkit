# frozen_string_literal: true

# Authority-path discovery tool: lists every read-only resource registered in the
# config's Registry, HIDING superuser-only resources from a non-superuser caller
# (so they are neither advertised nor discoverable without a superuser token).
#
# The top-level list is context-independent except for that visibility filter, so
# the tool takes no arguments and does no per-resource scope check (per-resource
# scopes are enforced by `get` / `list` / `resource_schema`).
class McpToolkit::Authority::Tools::Resources < McpToolkit::Authority::Tools::Base
  tool_name "resources"
  description <<~DESC.strip
    List all read-only resources available via the `list` and `get` tools. Returns each
    resource's name, a short description, whether it accepts filters (`filterable`) and — when
    present — a usage `note` (read it before interpreting the resource's data). Call this once
    at the start of a session to learn what exists, then use `resource_schema` for a specific
    resource's attributes, relationships and filters.
  DESC

  def call(context:, **_args)
    {
      resources: visible_resources(context).map do |resource|
        {
          name: resource.name,
          description: resource.description,
          filterable: filterable?(resource),
          note: resource.note
        }.compact
      end
    }
  end

  private

  # Superuser-only resources are hidden from a non-superuser caller.
  def visible_resources(context)
    registry.resources.reject { |resource| resource.superusers_only? && !context.superuser? }
  end

  # Whether the resource can be filtered at all — via the generic allowlist OR a
  # resource-specific custom filter. Reading `filterable_columns` resolves a
  # lazily-declared allowlist, which may run host code (e.g. a DB-backed column
  # list). One resource's failing resolution must not take down the whole
  # discovery index — this is the tool every session calls first — so a raise
  # degrades to nil (the `filterable` key is omitted for that resource) and the
  # unresolved source is retried on the next read (see Resource#filterable).
  def filterable?(resource)
    resource.filterable_columns.any? || resource.custom_filters.any?
  rescue StandardError => e
    config.logger&.warn("mcp_toolkit: filterable resolution failed for #{resource.name}: #{e.message}")
    nil
  end
end
