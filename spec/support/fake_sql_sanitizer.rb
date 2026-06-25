# frozen_string_literal: true

# A DB-free stand-in for the ActiveRecord-backed McpToolkit::SqlSanitizer, used
# by the specs that exercise `matches` / `does_not_match` filtering without a
# Rails/ActiveRecord dependency. Escapes the LIKE wildcards (`\`, `%`, `_`) the
# same way `ActiveRecord::Base.sanitize_sql_like` would.
class FakeSqlSanitizer
  def sanitize_sql_like(string)
    string.gsub(/([\\%_])/, '\\\\\1')
  end
end
