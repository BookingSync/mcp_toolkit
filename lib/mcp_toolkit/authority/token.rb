# frozen_string_literal: true

require "active_support/core_ext/integer/time"

# Generic, ownership-agnostic machinery for an AUTHORITY's access-token model,
# packaged as a concern to `include` into a host's ActiveRecord token model. It
# extracts everything about a token that is NOT specific to the host's tenancy
# model (how a token maps to accounts/users), leaving the host to declare only its
# ownership associations, account resolution, and any bespoke validations.
#
# Expected columns on the including model:
#   token_digest  :string   NOT NULL, unique — SHA256(plaintext) for O(1) lookup
#   token_prefix  :string   NOT NULL — first 11 plaintext chars, safe to display
#   scopes        :string[] / json — OAuth-style "<app>__<action>" grants (nullable)
#   expires_at    :datetime nullable — nil = never expires
#   last_used_at  :datetime nullable — throttled touch (see #touch_last_used!)
#
# What it provides:
#   * Secure token generation on create (`assign_token`) + the plaintext reader
#     (`#token`, populated only on the instance that generated it).
#   * Lookup/verification: `.authenticate(plaintext)` / `.digest_for(plaintext)`.
#   * Lifecycle scopes (`active` / `expired` / `never_used` / `used_within`) and
#     `#expired?`, plus the throttled `#touch_last_used!`.
#   * OAuth-style scope helpers (`#normalized_scopes` / `#authorized_for_scope?` /
#     `#scope_restricted?`).
#
# Why a plain SHA256 (not bcrypt/scrypt/argon2): the token is a high-entropy random
# secret (24 bytes over a 64-char alphabet ≈ 144 bits), so rainbow tables can't
# exist and brute force is infeasible — the slow KDFs that protect low-entropy
# passwords buy nothing and would break the O(1) `find_by(token_digest:)` lookup.
module McpToolkit::Authority::Token
  extend ActiveSupport::Concern

  # Plaintext token layout. "mcp_" is the MCP-generic scheme prefix (not a host
  # fingerprint); the display length is that prefix plus 7 random chars.
  TOKEN_PREFIX = "mcp_"
  RAW_TOKEN_BYTES = 24
  TOKEN_PREFIX_DISPLAY_LENGTH = 11

  # Skip the last_used_at UPDATE unless this much time has passed, so a burst of
  # calls doesn't write on every request.
  LAST_USED_AT_THROTTLE = 1.minute

  included do
    # The plaintext token: only populated on the in-memory instance that just
    # generated it; nil on any reloaded/queried instance (we never store plaintext).
    attr_reader :token

    # Defense-in-depth presence checks (the columns are NOT NULL at the DB level);
    # the host adds its own uniqueness enforcement suited to its stack.
    validates :token_digest, presence: true
    validates :token_prefix, presence: true

    before_validation :assign_token, on: :create

    scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }
    scope :expired, -> { where("expires_at IS NOT NULL AND expires_at <= ?", Time.current) }
    scope :never_used, -> { where(last_used_at: nil) }
    scope :used_within, ->(duration) { where(last_used_at: duration.ago..) }
  end

  module ClassMethods
    # Looks up an active token by its plaintext value; nil for blank/unknown/expired.
    def authenticate(plaintext)
      return nil if plaintext.blank?

      active.find_by(token_digest: digest_for(plaintext))
    end

    def digest_for(plaintext)
      Digest::SHA256.hexdigest(plaintext)
    end
  end

  def reload(...)
    @token = nil
    super
  end

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  # The OAuth-style scopes granted to this token as a clean array of "<app>__<action>"
  # strings. An unrestricted token (NULL/empty `scopes`) returns [].
  def normalized_scopes
    Array(scopes).compact_blank
  end

  # Per-scope check. A tool requiring no scope is reachable by any token; a tool
  # requiring a scope needs the token to HOLD that exact scope. An unrestricted
  # token holds NO scopes, so it can reach only no-scope tools.
  def authorized_for_scope?(scope)
    return true if scope.blank?

    normalized_scopes.include?(scope.to_s)
  end

  # True when the token carries an explicit scope set (i.e. is restricted).
  def scope_restricted?
    normalized_scopes.any?
  end

  # Throttled last_used_at bump: persists on its own, without validations or
  # bumping updated_at, and only once per LAST_USED_AT_THROTTLE window.
  def touch_last_used!
    return unless last_used_at.nil? || last_used_at < LAST_USED_AT_THROTTLE.ago

    self.last_used_at = Time.current
    save!(validate: false, touch: false)
  end

  private

  def assign_token
    return if token_digest.present?

    @token = "#{TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(RAW_TOKEN_BYTES)}"
    self.token_digest = self.class.digest_for(@token)
    # Plain-Ruby slice (not String#first) so the concern needs no ActiveSupport
    # string core-ext; the token is always longer than the display length.
    self.token_prefix = @token[0, TOKEN_PREFIX_DISPLAY_LENGTH]
  end
end
