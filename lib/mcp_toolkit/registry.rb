# frozen_string_literal: true

# `did_you_mean` is a Ruby default gem (loaded at interpreter startup on stock
# builds), used to suggest the closest registered resource name on a typo. A
# trimmed runtime without it falls back to the small edit-distance matcher below,
# so the require is guarded rather than assumed.
begin
  require "did_you_mean"
rescue LoadError
  nil
end

# Central registry of read-only resources exposed via the MCP server. Resources
# are registered at boot (in a `to_prepare` initializer) and consumed by the
# generic `resources` / `resource_schema` / `get` / `list` tools.
#
# Instances are addressable so tests (and, in principle, multiple mounted
# servers) don't collide; the app-facing convenience is `McpToolkit.registry`,
# which returns the process-wide instance.
class McpToolkit::Registry
  class UnknownResource < StandardError; end

  # When the catalog has at most this many resources, the UnknownResource message
  # lists all of them (cheap for a caller to scan); above it, only the closest
  # suggestions are offered so the message stays short.
  FULL_LIST_MAX = 10
  # Cap on the number of "did you mean" suggestions offered for a near-miss name.
  MAX_SUGGESTIONS = 3

  def initialize
    @resources = {}
    @default_required_permissions_scope = nil
  end

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
    resource.instance_eval(&)
    @resources[name.to_s] = resource
  end

  # The scope a token must carry to reach `resource` via the generic tools: the
  # resource's own declared scope, else the registry default, else nil (no check).
  def required_scope_for(resource)
    resource.effective_required_permissions_scope(@default_required_permissions_scope)
  end

  def fetch(name)
    find(name) or raise(UnknownResource, unknown_resource_message(name))
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
  # in `to_prepare`). The `default_required_permissions_scope` is PRESERVED, since
  # it's declared once in `configure` rather than per-reload.
  def reset!
    @resources = {}
  end

  private

  # Builds the UnknownResource message: states the bad name, then (a) suggests the
  # nearest registered name(s) for a near-miss and (b) — when the catalog is short —
  # lists them all, so a caller (typically an MCP agent that guessed a name) can
  # self-correct without another round-trip to the `resources` tool.
  def unknown_resource_message(name)
    message = "unknown resource: #{name.inspect}"
    names = resource_names
    return message if names.empty?

    suggestions = suggestions_for(name.to_s, names)
    message += ". Did you mean #{quote_join(suggestions)}?" if suggestions.any?
    message += " Registered resources: #{quote_join(names.sort)}." if names.size <= FULL_LIST_MAX
    message
  end

  # Closest registered names to a near-miss. Uses Ruby's stdlib DidYouMean spell
  # checker when available (typo/transposition aware), else the prefix/substring +
  # edit-distance fallback below.
  def suggestions_for(name, names)
    if defined?(DidYouMean::SpellChecker)
      Array(DidYouMean::SpellChecker.new(dictionary: names).correct(name)).first(MAX_SUGGESTIONS)
    else
      fallback_suggestions(name, names)
    end
  end

  # Fallback matcher for a runtime without `did_you_mean`: keep names that share a
  # prefix/substring with the target or are within a small edit distance, closest
  # first.
  def fallback_suggestions(name, names)
    target = name.downcase
    matches = names.select { |candidate| near_miss?(candidate.downcase, target) }
    matches.sort_by { |candidate| levenshtein(candidate.downcase, target) }.first(MAX_SUGGESTIONS)
  end

  def near_miss?(candidate, target)
    candidate.start_with?(target) || target.start_with?(candidate) ||
      candidate.include?(target) || levenshtein(candidate, target) <= 2
  end

  # Iterative Levenshtein edit distance (two-row DP) — small dictionaries, so an
  # exact distance is cheap and keeps the fallback dependency-free.
  def levenshtein(source, target)
    return target.length if source.empty?
    return source.length if target.empty?

    previous = (0..target.length).to_a
    source.each_char.with_index do |source_char, row|
      current = [row + 1]
      target.each_char.with_index do |target_char, col|
        cost = source_char == target_char ? 0 : 1
        current << [previous[col + 1] + 1, current[col] + 1, previous[col] + cost].min
      end
      previous = current
    end
    previous.last
  end

  def quote_join(names)
    names.map { |name| "\"#{name}\"" }.join(", ")
  end
end
