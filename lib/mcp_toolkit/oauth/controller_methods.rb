# frozen_string_literal: true

# The AUTHORITY-side OAuth 2.1 authorization bridge, provided as an includable
# concern.
#
# WHY THIS EXISTS. Hosted MCP clients will not send a bearer token an operator
# typed into a config file: they discover an authorization server, run an
# authorization-code + PKCE flow in a browser, and use whatever `access_token`
# comes back. The MCP authorization spec also forbids a token in the request URI
# query string, so `?token=<...>` is not an option for those clients either.
#
# WHAT THIS IS NOT. This is not an identity provider. It mints no credential,
# stores no client, models no consent, and issues no refresh token. It is a
# STANDARDS-SHAPED ENVELOPE around tokens the host ALREADY issues by its own
# means: the authorization page asks the operator to paste an existing access
# token, and the `access_token` this bridge hands back IS that token, verified
# through the same `config.token_authenticator` the transport uses. Every
# property that actually gates access — scopes, expiry, revocation, tenancy —
# stays exactly where the host put it. Nothing here widens who can reach what.
#
# The deliberate no-ops, so a reader does not mistake them for oversights:
#   * client registration returns a fresh identifier and stores nothing; no
#     endpoint ever checks a `client_id`, because a public client's identifier is
#     self-asserted and gates nothing on its own;
#   * there is no consent step — the operator pasting a token they already hold
#     IS the grant;
#   * no refresh token is issued. The pasted token's own expiry is the real
#     lifetime, so a client re-runs this flow rather than refreshing a shadow of
#     it.
#
# The two things that are NOT mocked, because faking them would create a real
# vulnerability rather than skip a ceremony:
#   * `redirect_uri` is matched against `config.oauth_allowed_redirect_uris` by
#     exact string, on BOTH legs. An unvetted redirect target here would be an
#     open redirect that hands out authorization codes.
#   * the PKCE `code_verifier` is verified against the stored `code_challenge`.
#     It is a few lines and it is what stops an intercepted code from being
#     redeemed by anyone but its requester.
#
# Endpoints (mount path `<mcp>` = wherever the host mounted McpToolkit::Engine)
#   GET  /.well-known/oauth-protected-resource  - protected-resource metadata (RFC 9728)
#   GET  /.well-known/oauth-authorization-server- authorization-server metadata (RFC 8414)
#   POST <mcp>/oauth/register                   - client registration (RFC 7591), a stub
#   GET  <mcp>/oauth/authorize                  - the paste-your-token page
#   POST <mcp>/oauth/authorize                  - validate the paste, issue a code
#   POST <mcp>/oauth/token                      - exchange code (+ verifier) for the token
#
# The two metadata documents must answer at the ORIGIN ROOT, which an engine
# mounted under a path cannot draw. The host draws them in one line at the top
# level of its own route set:
#
#   # config/routes.rb — top level, NOT inside a locale/format scope
#   McpToolkit.draw_oauth_metadata_routes(self)
#
# Rendering: the authorization page is an HTML view, so the configured
# `parent_controller` must descend from ActionController::Base (ActionController::API
# cannot render one). A host restyles the page by defining its own
# `app/views/mcp_toolkit/oauth/authorize.html.erb`, which takes precedence over
# the engine's.
module McpToolkit::Oauth::ControllerMethods
  extend ActiveSupport::Concern

  CODE_CACHE_PREFIX = "mcp_toolkit:oauth:code:"
  CODE_BYTES = 32
  PROTECTED_RESOURCE_PATH = "/.well-known/oauth-protected-resource"
  AUTHORIZATION_SERVER_PATH = "/.well-known/oauth-authorization-server"

  included do
    # The token endpoint is called server-to-server by the client with no CSRF
    # token; the authorization form posts with one. Skipping forgery protection
    # for the former only would need per-action config on a dynamically built
    # class, so the form carries its own guarantee instead: `approve` never acts
    # on ambient authority (no cookie, no session), only on a pasted token, and
    # its sole side effect redirects to an allowlisted URI.
    protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)
  end

  # GET /.well-known/oauth-protected-resource
  # Points a client at this app as its own authorization server. `resource` MUST
  # equal the MCP endpoint URL as the operator typed it into the client, so it is
  # derived from the live request origin rather than pinned to one host.
  def protected_resource
    render json: {
      resource: mcp_oauth_resource_url,
      authorization_servers: [mcp_oauth_issuer],
      bearer_methods_supported: ["header"]
    }
  end

  # GET /.well-known/oauth-authorization-server
  # Advertises S256 because clients send a `code_challenge` regardless; `none`
  # for token-endpoint auth because clients here are public and unverified.
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

  # POST <mcp>/oauth/register
  # Deliberately stateless: hand back an identifier, remember nothing. Nothing
  # downstream reads it, so persisting it would only grow a table of strings the
  # bridge never consults.
  def register
    render json: {
      client_id: SecureRandom.uuid,
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code"],
      response_types: ["code"]
    }, status: :created
  end

  # GET <mcp>/oauth/authorize — renders the paste-your-token page.
  def authorize
    return mcp_oauth_render_bad_request(mcp_oauth_request_problem) if mcp_oauth_request_problem

    render :authorize, layout: false
  end

  # POST <mcp>/oauth/authorize — verify the pasted token, mint a code, hand the
  # client back to its redirect_uri. The token is verified here (rather than only
  # at exchange) so a typo fails on the page the operator is looking at.
  def approve
    return mcp_oauth_render_bad_request(mcp_oauth_request_problem) if mcp_oauth_request_problem

    access_token = params[:access_token].to_s
    return mcp_oauth_reject_paste if mcp_oauth_authenticate(access_token).nil?

    redirect_to mcp_oauth_callback_url(mcp_oauth_issue_code(access_token)), allow_other_host: true
  end

  # POST <mcp>/oauth/token — exchange a one-time code for the pasted token.
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

  # The only two things worth refusing outright. A disallowed redirect_uri must
  # never be redirected TO (that is the attack), so both problems render here
  # instead of bouncing an OAuth error back to the caller.
  def mcp_oauth_request_problem
    return "Unregistered redirect_uri." unless mcp_oauth_redirect_uri_allowed?
    return "Missing or unsupported PKCE code_challenge." unless mcp_oauth_code_challenge_supported?

    nil
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

  # The origin. Metadata answers at the origin root, so the issuer is the origin
  # and a client's RFC 8414 lookup lands on a path we actually draw.
  def mcp_oauth_issuer
    request.base_url
  end

  # The MCP endpoint itself — origin + the engine's mount path.
  def mcp_oauth_resource_url
    "#{request.base_url}#{mcp_oauth_config.oauth_resource_path}"
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
