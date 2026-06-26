# frozen_string_literal: true

# Escapes LIKE wildcards (`%`, `_`, `\`) in a string so a `matches` /
# `does_not_match` filter value is matched literally rather than as a pattern.
#
# The default implementation delegates to ActiveRecord's
# `sanitize_sql_like` (production); it is injected via
# `Configuration#sql_sanitizer` so a non-Rails host (or a test) can supply its
# own. Filtering calls `config.sql_sanitizer.sanitize_sql_like(value)`.
class McpToolkit::SqlSanitizer
  def sanitize_sql_like(string)
    ActiveRecord::Base.sanitize_sql_like(string)
  end
end
