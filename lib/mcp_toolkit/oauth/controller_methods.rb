# frozen_string_literal: true

# The AUTHORITY-side OAuth 2.1 authorization bridge (routes: config/routes.rb;
# setup + rationale: README).
#
# NOT an identity provider, and reading it as a half-built one will mislead. It
# mints no credential, stores no client, models no consent, issues no refresh
# token. It is a standards-shaped envelope around tokens the host ALREADY issues
# by its own means, for clients that will only authenticate by discovering an
# authorization server and running a browser flow: the page asks an operator to
# paste a token they hold, and the `access_token` returned IS that token, verified
# through the same `config.token_authenticator` the transport uses. Scopes,
# expiry, revocation and tenancy stay with the host; nothing here widens reach.
#
# So the stubs are deliberate, not unfinished: no endpoint reads the `client_id`
# it hands out (a public client's identifier is self-asserted and gates nothing);
# pasting a token you already hold IS the grant; and the pasted token's own expiry
# is the real lifetime, so a client re-runs the flow rather than refreshing a
# shadow of it.
#
# Two things are NOT mocked, because faking them would be a vulnerability rather
# than a skipped ceremony: `redirect_uri` is exact-matched against the allowlist
# on BOTH legs (an unvetted target is an open redirect handing out authorization
# codes), and the PKCE `code_verifier` is verified.
module McpToolkit::Oauth::ControllerMethods
  extend ActiveSupport::Concern

  CODE_CACHE_PREFIX = "mcp_toolkit:oauth:code:"
  CODE_BYTES = 32

  included do
    # Safe to disable: the token endpoint is called server-to-server without a CSRF
    # token, and `approve` never acts on ambient authority — no cookie, no session,
    # only a pasted token, redirecting to an allowlisted URI.
    protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)
  end

  # `resource` MUST equal the MCP endpoint URL as the operator typed it into the
  # client, hence derived from the live request origin rather than pinned.
  def protected_resource
    render json: {
      resource: mcp_oauth_resource_url,
      authorization_servers: [mcp_oauth_issuer],
      bearer_methods_supported: ["header"]
    }
  end

  # S256 because clients send a `code_challenge` regardless; `none` because the
  # clients here are public and unverified.
  def authorization_server
    render json: {
      issuer: mcp_oauth_issuer,
      authorization_endpoint: mcp_oauth_endpoint_url("authorize"),
      token_endpoint: mcp_oauth_endpoint_url("token"),
      registration_endpoint: mcp_oauth_endpoint_url("register"),
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"]
    }
  end

  # Stateless: persisting a `client_id` nothing reads would only grow a table of
  # strings the bridge never consults.
  def register
    render json: {
      client_id: SecureRandom.uuid,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code"],
      response_types: ["code"]
    }, status: :created
  end

  def authorize
    problem = mcp_oauth_request_problem
    return mcp_oauth_render_bad_request(problem) if problem

    render :authorize, layout: false
  end

  # The token is verified here, not only at exchange, so a typo fails on the page
  # the operator is looking at.
  def approve
    problem = mcp_oauth_request_problem
    return mcp_oauth_render_bad_request(problem) if problem

    access_token = params[:access_token].to_s
    return mcp_oauth_reject_paste if mcp_oauth_authenticate(access_token).nil?

    redirect_to mcp_oauth_callback_url(mcp_oauth_issue_code(access_token)), allow_other_host: true
  end

  def token
    return mcp_oauth_render_token_error("unsupported_grant_type") unless params[:grant_type] == "authorization_code"

    payload = mcp_oauth_consume_code(params[:code].to_s)
    return mcp_oauth_render_token_error("invalid_grant") if payload.nil?
    return mcp_oauth_render_token_error("invalid_grant") unless mcp_oauth_exchange_valid?(payload)

    access_token = payload[:access_token].to_s
    return mcp_oauth_render_token_error("invalid_grant") if mcp_oauth_authenticate(access_token).nil?

    render json: { access_token:, token_type: "Bearer" }
  end

  private

  def mcp_oauth_config
    McpToolkit.config
  end

  # ---- request validation ---------------------------------------------------

  # Both problems render rather than bounce an OAuth error back to the caller: a
  # disallowed redirect_uri must never be redirected TO — that is the attack.
  def mcp_oauth_request_problem
    return mcp_oauth_reject_redirect_uri unless mcp_oauth_redirect_uri_allowed?
    return "Missing or unsupported PKCE code_challenge." unless mcp_oauth_code_challenge_supported?

    nil
  end

  # Exact matching makes a legitimate client rejected over a trailing slash look
  # identical to an attack, so log the offered value (a public callback, never a
  # credential) — otherwise an operator is left guessing what to allowlist.
  def mcp_oauth_reject_redirect_uri
    mcp_oauth_config.logger&.warn(
      "[mcp_toolkit] OAuth authorize rejected: redirect_uri #{params[:redirect_uri].inspect} is not in " \
      "config.oauth_allowed_redirect_uris (#{Array(mcp_oauth_config.oauth_allowed_redirect_uris).inspect})"
    )
    "Unregistered redirect_uri."
  end

  def mcp_oauth_redirect_uri_allowed?
    Array(mcp_oauth_config.oauth_allowed_redirect_uris).include?(params[:redirect_uri].to_s)
  end

  def mcp_oauth_code_challenge_supported?
    params[:code_challenge].present? && params[:code_challenge_method].to_s == "S256"
  end

  # ---- authorization codes --------------------------------------------------

  # The whole "authorization server" state: one cache entry, short-lived, bound
  # to the challenge and redirect it was issued for.
  def mcp_oauth_issue_code(access_token)
    code = SecureRandom.urlsafe_base64(CODE_BYTES)
    mcp_oauth_config.cache_store.write(
      "#{CODE_CACHE_PREFIX}#{code}",
      { access_token:, code_challenge: params[:code_challenge].to_s, redirect_uri: params[:redirect_uri].to_s },
      expires_in: mcp_oauth_config.oauth_authorization_code_ttl
    )
    code
  end

  # Read-and-delete: a code is single-use even if the exchange then fails.
  def mcp_oauth_consume_code(code)
    return nil if code.empty?

    key = "#{CODE_CACHE_PREFIX}#{code}"
    payload = mcp_oauth_config.cache_store.read(key)
    mcp_oauth_config.cache_store.delete(key)
    payload
  end

  def mcp_oauth_exchange_valid?(payload)
    payload[:redirect_uri] == params[:redirect_uri].to_s &&
      mcp_oauth_pkce_valid?(params[:code_verifier].to_s, payload[:code_challenge].to_s)
  end

  # S256: base64url(sha256(verifier)), unpadded. Packed rather than via base64 so
  # the gem needs no extra dependency.
  def mcp_oauth_pkce_valid?(verifier, challenge)
    return false if verifier.empty? || challenge.empty?

    digest = [Digest::SHA256.digest(verifier)].pack("m0").tr("+/", "-_").delete("=")
    ActiveSupport::SecurityUtils.secure_compare(digest, challenge)
  end

  # ---- token verification ---------------------------------------------------

  # The same authenticator the transport authenticates every MCP request with —
  # this bridge introduces no second notion of a valid token.
  def mcp_oauth_authenticate(access_token)
    return nil if access_token.empty?

    McpToolkit::Auth::Authority.authenticate(access_token, config: mcp_oauth_config)
  end

  # ---- urls -----------------------------------------------------------------

  # Deliberately path-ful: a client path-INSERTS this to find the metadata, which
  # is what keeps the bridge off the origin-global bare path (see
  # Configuration#oauth_protected_resource_path). Issuer path == resource path, so
  # a client derives the same URL from either.
  def mcp_oauth_issuer
    mcp_oauth_resource_url
  end

  def mcp_oauth_resource_url
    "#{request.base_url}#{mcp_oauth_config.oauth_resource_path_component}"
  end

  def mcp_oauth_endpoint_url(action)
    "#{mcp_oauth_resource_url}/oauth/#{action}"
  end

  # Appends `code` (and echoes `state`) onto the client's redirect_uri, preserving
  # any query it already carries.
  def mcp_oauth_callback_url(code)
    uri = URI.parse(params[:redirect_uri].to_s)
    query = URI.decode_www_form(uri.query.to_s)
    query << ["code", code]
    query << ["state", params[:state].to_s] if params[:state].present?
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  # ---- responses ------------------------------------------------------------

  def mcp_oauth_reject_paste
    @mcp_oauth_error = "That access token is not valid, or it has expired or been revoked."
    render :authorize, layout: false, status: :unprocessable_content
  end

  def mcp_oauth_render_bad_request(message)
    render plain: message, status: :bad_request
  end

  def mcp_oauth_render_token_error(code)
    render json: { error: code }, status: :bad_request
  end
end
