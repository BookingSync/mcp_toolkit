# frozen_string_literal: true

# AUTHORITY side. The helpers the central app uses to (a) authenticate a
# plaintext bearer token against its local token store and (b) answer the
# introspection request satellites send.
#
# Both are thin and config-driven: the actual token lookup is the app's
# `config.token_authenticator` callable (its `McpToken.authenticate`
# equivalent), and the introspection payload is derived from the duck-typed
# token object that callable returns.
#
# ## Token object contract
#
# `config.token_authenticator.call(plaintext)` must return nil (no/invalid
# token) or an object responding to:
#
#   #kind            -> :accounts_user | :user (or string equivalents)
#   #account_id      -> the single bound account id for an accounts_user token,
#                       else nil
#   #account_ids     -> Array of authorized account ids
#   #expires_at      -> a Time/DateTime responding to #iso8601, or nil
#   #scopes          -> Array of OAuth-style `<app>__<action>` scopes ([] = unrestricted).
#                       The sole authorization source on the satellite side.
#
# Optionally `#touch_last_used!` (called after a successful authenticate if
# present). A typical app token model (e.g. `McpToken`) satisfies this.
module McpToolkit::Auth::Authority
  module_function

  # Authenticate a plaintext bearer locally. Returns the token object or nil.
  # Calls `touch_last_used!` on the token if it responds to it (throttled
  # last-used tracking is the token model's concern, not ours).
  def authenticate(plaintext, config: McpToolkit.config)
    authenticator = config.token_authenticator
    if authenticator.nil?
      raise McpToolkit::Errors::ConfigurationError,
            "token_authenticator is not configured; required for the :authority role"
    end

    token = authenticator.call(plaintext)
    return nil unless token

    token.touch_last_used! if token.respond_to?(:touch_last_used!)
    token
  end

  # Build the introspection response payload for a token object. This is the
  # JSON the authority's `/mcp/tokens/introspect` endpoint renders, and the
  # exact contract Auth::Introspection (the satellite) parses.
  #
  # @param token [#kind, #account_id, #account_ids, #expires_at, #scopes]
  # @return [Hash]
  def introspection_payload(token)
    account_ids = Array(token.account_ids)
    {
      valid: true,
      kind: token.kind.to_s,
      account_id: account_id_for(token, account_ids),
      account_ids:,
      expires_at: token.expires_at&.iso8601,
      scopes: Array(token.scopes)
    }
  end

  # The payload returned for a missing/invalid token. Render with HTTP 401.
  def invalid_payload
    { valid: false }
  end

  # account_id is the single bound account for an accounts_user token, else nil
  # (a superuser/multi-account token advertises its set via account_ids).
  def account_id_for(token, account_ids)
    return token.account_id if token.respond_to?(:account_id) && token.account_id

    token.kind.to_s == "accounts_user" ? account_ids.first : nil
  end
end
