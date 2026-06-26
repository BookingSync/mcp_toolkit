# frozen_string_literal: true

# SATELLITE side. Resolves the authenticated, scoped context for a tool call:
#
#   1. Introspect the bearer token against the central app (cached).
#   2. Reject if invalid / expired.
#   3. Resolve the active central account id, enforcing tenancy:
#        - accounts_user token  => its single bound `account_id`. A supplied
#          selector, if present, MUST match it.
#        - user (superuser) token => the selector is REQUIRED and MUST be one of
#          the token's `account_ids`.
#   4. Map that central account id to the LOCAL scope root via
#      `config.account_resolver` (e.g. Account.find_by(synced_id:)) and return
#      it as the tools' `scope_root`.
#
# The required scope (explicitly declared per resource via
# `required_permissions_scope`, or the registry default) is enforced separately
# by Tools::Base (#with_account / #with_authentication) via
# `authorized_for_scope?`; the authenticator only validates the token and
# resolves the tenant.
#
# The account selector mirrors what a gateway forwards: the resolved account id
# arrives as `_meta[config.account_meta_key]`. We also accept an `account_id`
# tool argument and the `config.account_id_header` header as fallbacks.
class McpToolkit::Auth::Authenticator
  Context = Struct.new(:scope_root, :introspection, keyword_init: true)

  # @param token [String] the plaintext bearer the central app forwarded
  # @param meta [Hash] the JSON-RPC `_meta` (string or symbol keys)
  # @param arguments [Hash] the tool-call arguments (may carry `account_id`)
  # @param header_account_id [Integer,String,nil] the account-id header value
  # @param config [McpToolkit::Configuration]
  def self.call(token:, meta: {}, arguments: {}, header_account_id: nil, config: McpToolkit.config)
    new(token:, meta:, arguments:, header_account_id:, config:).call
  end

  def initialize(token:, meta:, arguments:, header_account_id:, config: McpToolkit.config)
    @token = token
    @meta = (meta || {}).transform_keys(&:to_s)
    @arguments = (arguments || {}).transform_keys(&:to_s)
    @header_account_id = header_account_id
    @config = config
  end

  def call
    introspection = McpToolkit::Auth::Introspection.call(token, config:)
    raise McpToolkit::Errors::Unauthorized, "invalid or expired token" unless introspection.valid?

    central_account_id = resolve_account_id(introspection)
    scope_root = config.account_resolver.call(central_account_id)
    unless scope_root
      raise McpToolkit::Errors::Unauthorized, "no local scope found for account_id=#{central_account_id}"
    end

    Context.new(scope_root:, introspection:)
  end

  private

  attr_reader :token, :meta, :arguments, :header_account_id, :config

  def resolve_account_id(introspection)
    candidate = candidate_account_id

    if introspection.accounts_user?
      bound = introspection.account_id
      # Compare as STRINGS: ids may be numeric or string/UUID, and to_i would
      # collapse every non-numeric id to 0 (letting "acct_B" match "acct_A").
      if candidate.present? && candidate.to_s != bound.to_s
        raise McpToolkit::Errors::Unauthorized,
              "account_id #{candidate} does not match this token's bound account"
      end

      return bound.to_s
    end

    # superuser / multi-account: selection is mandatory and must be authorized.
    if candidate.blank?
      raise McpToolkit::Errors::Unauthorized,
            "this token spans multiple accounts; an account must be selected " \
            "via _meta[\"#{config.account_meta_key}\"] (or the account_id argument)"
    end

    # String-normalized membership (see accounts_user branch): `candidate` may be
    # an Integer (forwarded `_meta` JSON number) or a String (header/arg); to_s
    # normalizes both and authorized_account_ids is likewise string-normalized.
    unless introspection.authorized_account_ids.include?(candidate.to_s)
      raise McpToolkit::Errors::Unauthorized, "account_id #{candidate} is not authorized for this token"
    end

    candidate.to_s
  end

  def candidate_account_id
    meta[config.account_meta_key].presence ||
      arguments["account_id"].presence ||
      header_account_id.presence
  end
end
