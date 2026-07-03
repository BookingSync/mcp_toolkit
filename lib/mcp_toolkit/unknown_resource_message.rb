# frozen_string_literal: true

begin
  require "did_you_mean"
rescue LoadError
  nil
end

# Builds the McpToolkit::Registry::UnknownResource message from a bad name and the
# registered resource names: it states the bad name, then (a) suggests the nearest
# registered name(s) for a near-miss — via Ruby's stdlib DidYouMean spell checker
# when available, else a dependency-free prefix/substring + edit-distance fallback —
# and (b), when the catalog is short, lists them all, so a caller (typically an MCP
# agent that guessed a name) can self-correct without another round-trip to the
# `resources` tool.
class McpToolkit::UnknownResourceMessage
  FULL_LIST_MAX = 10
  MAX_SUGGESTIONS = 3

  def initialize(name, resource_names)
    @name = name
    @resource_names = resource_names
  end

  def build
    message = "unknown resource: #{@name.inspect}"
    return message if @resource_names.empty?

    suggestions = suggestions_for(@name.to_s, @resource_names)
    message += ". Did you mean #{quote_join(suggestions)}?" if suggestions.any?
    message += " Registered resources: #{quote_join(@resource_names.sort)}." if @resource_names.size <= FULL_LIST_MAX
    message
  end

  private

  def suggestions_for(name, names)
    if defined?(DidYouMean::SpellChecker)
      Array(DidYouMean::SpellChecker.new(dictionary: names).correct(name)).first(MAX_SUGGESTIONS)
    else
      fallback_suggestions(name, names)
    end
  end

  def fallback_suggestions(name, names)
    target = name.downcase
    matches = names.select { |candidate| near_miss?(candidate.downcase, target) }
    matches.sort_by { |candidate| levenshtein(candidate.downcase, target) }.first(MAX_SUGGESTIONS)
  end

  def near_miss?(candidate, target)
    candidate.start_with?(target) || target.start_with?(candidate) ||
      candidate.include?(target) || levenshtein(candidate, target) <= 2
  end

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
