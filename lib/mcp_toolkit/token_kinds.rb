# frozen_string_literal: true

# The token "kind" domain values, shared by the collaborating auth objects so the
# string literals live in exactly one place. The authority emits these in the
# introspection payload (`kind`); the satellite reads them back
# (`Auth::Introspection::Result#accounts_user?` / `#superuser?`).
#
#   ACCOUNTS_USER - a token bound to a single account.
#   USER          - a superuser / multi-account token (advertises its set via
#                   `account_ids`).
module McpToolkit::TokenKinds
  ACCOUNTS_USER = "accounts_user"
  USER = "user"
end
