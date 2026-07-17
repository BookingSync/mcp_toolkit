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
# than a skipped ceremony: `redirect_uri` is checked against the host's policy on
# BOTH legs (an unvetted REMOTE target is an open redirect handing out
# authorization codes — see Configuration#oauth_allowed_redirect_uris for the
# attack it stops), and the PKCE `code_verifier` is verified.
module McpToolkit::Oauth::ControllerMethods
  extend ActiveSupport::Concern

  CODE_CACHE_PREFIX = "mcp_toolkit:oauth:code:"
  CODE_BYTES = 32

  # Query parameters the callback response owns: whatever a client put in its own
  # redirect_uri, these are set by the redirect and not carried over from it.
  RESPONSE_OWNED_QUERY_KEYS = %w[code state].freeze

  # RFC 7636 §4.1: 43–128 unreserved characters. The challenge is §4.2's
  # base64url of a SHA-256, which is always exactly 43 of the same alphabet.
  PKCE_VALUE = /\A[A-Za-z0-9\-._~]{43,128}\z/

  included do
    # Safe to disable: the token endpoint is called server-to-server without a CSRF
    # token, and `approve` never acts on ambient authority — it reads no session and
    # no cookie, only a pasted token, redirecting to a host-permitted URI. (The GET
    # leg does SET a session cookie, because `form_tag` emits an authenticity
    # token; nothing ever reads it back.)
    protect_from_forgery with: :null_session if respond_to?(:protect_from_forgery)

    # A before_action, not a guard clause in each action, because a callback runs
    # even when the action itself does not. `authorize` is a common enough method
    # name that a gem patching ActionController::Base with one would knock this
    # action out of Rails' `action_methods` — and Rails would then serve
    # `authorize.html.erb` by implicit render, skipping a body guard entirely and
    # showing an attacker's `redirect_uri` a paste page. Here the check cannot be
    # routed around.
    # Raises rather than skipping when the parent has no filter chain. Skipping
    # would leave both browser legs unguarded — an open redirect issuing codes to
    # any URI — and it is the same shape as the scheme denylist this branch
    # removed for failing open. A guard that installs itself conditionally is not
    # a guard.
    unless respond_to?(:before_action)
      raise McpToolkit::Errors::ConfigurationError,
            "#{name || "The OAuth bridge's parent"} has no `before_action`; " \
            "config.oauth_parent_controller must be an ActionController with a filter chain."
    end

    before_action :mcp_oauth_validate_request!, only: %i[authorize approve]
  end

  # `resource` MUST equal the MCP endpoint URL as the operator typed it into the
  # client, hence derived from the live request origin rather than pinned.
  def protected_resource
    mcp_oauth_forbid_caching
    render json: {
      resource: mcp_oauth_resource_url,
      authorization_servers: [mcp_oauth_issuer],
      bearer_methods_supported: ["header"]
    }
  end

  # S256 because clients send a `code_challenge` regardless; `none` because the
  # clients here are public and unverified.
  def authorization_server
    mcp_oauth_forbid_caching
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

  # `formats: [:html]` because there is only an HTML template and `Accept` picks
  # the format just as a `.json` suffix would — without it, `Accept:
  # application/json` raises MissingTemplate on an unauthenticated endpoint.
  def authorize
    render :authorize, layout: false, formats: [:html]
  end

  # The token is verified here, not only at exchange, so a typo fails on the page
  # the operator is looking at.
  def approve
    access_token = params[:access_token].to_s
    return mcp_oauth_reject_paste if mcp_oauth_authenticate(access_token).nil?

    # 303, not Rails' default 302: this POST carried the operator's token in its
    # body, and only 303 unambiguously tells the browser to fetch the redirect
    # target with GET and no body. A 302 leaves re-sending it to the client's
    # discretion, which would hand the token itself to the callback (RFC 9700
    # §4.12).
    redirect_to mcp_oauth_callback_url(mcp_oauth_issue_code(access_token)),
                allow_other_host: true, status: :see_other
  end

  def token
    return mcp_oauth_render_token_error("unsupported_grant_type") unless params[:grant_type] == "authorization_code"
    # Shape first, and BEFORE the code is consumed: a request that could never
    # verify shouldn't cost a legitimate client its code. A well-formed but WRONG
    # verifier still burns it below — that is deliberate, and the only thing
    # stopping someone who intercepted a code from retrying verifiers against it.
    return mcp_oauth_render_token_error("invalid_request") unless mcp_oauth_verifier_well_formed?

    payload = mcp_oauth_consume_code(params[:code].to_s)
    return mcp_oauth_render_token_error("invalid_grant") if payload.nil?
    return mcp_oauth_render_token_error("invalid_grant") unless mcp_oauth_exchange_valid?(payload)

    access_token = payload[:access_token].to_s
    return mcp_oauth_render_token_error("invalid_grant") if mcp_oauth_authenticate(access_token).nil?

    mcp_oauth_forbid_caching
    render json: { access_token:, token_type: "Bearer" }
  end

  private

  def mcp_oauth_config
    McpToolkit.config
  end

  # ---- request validation ---------------------------------------------------

  # Halts both legs before their action runs. Both problems RENDER rather than
  # bounce an OAuth error back to the caller: a disallowed redirect_uri must never
  # be redirected TO — that is the attack.
  def mcp_oauth_validate_request!
    problem = mcp_oauth_request_problem
    mcp_oauth_render_bad_request(problem) if problem
  end

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
      "config.oauth_allowed_redirect_uris (#{Array(mcp_oauth_config.oauth_allowed_redirect_uris).inspect}) " \
      "and is not a native-client target permitted by config.oauth_allow_loopback_redirects " \
      "(#{mcp_oauth_config.oauth_allow_loopback_redirects ? "enabled" : "disabled"})"
    )
    "Unregistered redirect_uri."
  end

  # Every target must be named exactly, with ONE exception: loopback, whose port
  # cannot be named ahead of time. See `mcp_oauth_loopback_redirect_uri?`.
  def mcp_oauth_redirect_uri_allowed?
    redirect_uri = params[:redirect_uri].to_s
    return false if redirect_uri.empty?
    return true if Array(mcp_oauth_config.oauth_allowed_redirect_uris).include?(redirect_uri)

    mcp_oauth_loopback_redirect_uri?(redirect_uri)
  end

  # RFC 8252 §7.3 loopback — the one target accepted unnamed, and only http(s) to
  # a loopback host: NOT private-use schemes, however local they look. See
  # Configuration#oauth_allow_loopback_redirects for why that line is drawn there.
  #
  # Judged on the PARSED URI, never the string, because `host` is what a browser
  # resolves: `http://127.0.0.1@evil.example/` (userinfo — host is evil.example)
  # and `http://127.0.0.1.evil.example/` are both correctly remote. A fragment is
  # refused because OAuth forbids one on a redirect_uri.
  def mcp_oauth_loopback_redirect_uri?(redirect_uri)
    return false unless mcp_oauth_config.oauth_allow_loopback_redirects

    uri = mcp_oauth_parse_uri(redirect_uri)
    return false if uri.nil?
    return false unless %w[http https].include?(uri.scheme&.downcase)
    return false unless uri.fragment.nil?

    mcp_oauth_loopback_host?(uri.host)
  end

  def mcp_oauth_parse_uri(value)
    URI.parse(value)
  rescue URI::InvalidURIError
    nil
  end

  # `URI` keeps the brackets on an IPv6 literal (`[::1]`); strip them so the
  # literal compares against the bare form clients actually send.
  def mcp_oauth_loopback_host?(host)
    McpToolkit::Oauth.loopback_host?(host)
  end

  # RFC 7636 §4.1/§4.2 shapes, not just presence. This cannot make a client's
  # PKCE strong — the challenge is a 43-char digest whatever the verifier was, so
  # a client that chose a one-character verifier is indistinguishable here and has
  # only defeated its own protection. It is enforced because a public gem should
  # not quietly accept what the spec forbids, and because a malformed value can
  # then be refused early rather than after a paste.
  def mcp_oauth_code_challenge_supported?
    params[:code_challenge].to_s.match?(PKCE_VALUE) && params[:code_challenge_method].to_s == "S256"
  end

  def mcp_oauth_verifier_well_formed?
    params[:code_verifier].to_s.match?(PKCE_VALUE)
  end

  # ---- authorization codes --------------------------------------------------

  # The whole "authorization server" state: one cache entry, short-lived, bound
  # to the challenge and redirect it was issued for.
  #
  # The entry is keyed by the code's DIGEST and its payload is sealed, so a dump
  # of the store yields nothing on its own. Worth the few lines because what is
  # parked there is not the short-lived credential an authorization server would
  # normally hold: it is the operator's pre-existing, long-lived, full-scope
  # token, in a store a host is told to point at its shared `Rails.cache`.
  def mcp_oauth_issue_code(access_token)
    code = SecureRandom.urlsafe_base64(CODE_BYTES)
    payload = {
      access_token:, code_challenge: params[:code_challenge].to_s, redirect_uri: params[:redirect_uri].to_s
    }
    mcp_oauth_config.cache_store.write(
      mcp_oauth_code_key(code),
      mcp_oauth_encryptor(code).encrypt_and_sign(JSON.generate(payload)),
      expires_in: mcp_oauth_config.oauth_authorization_code_ttl
    )
    code
  end

  # Single-use for real: the DELETE decides, not the read. `Cache::Store#delete`
  # answers whether the entry was still there, so of two concurrent redemptions
  # exactly one proceeds. (The race was never exploitable — both would return the
  # same token, and both need the verifier — but the guarantee is cheap to keep
  # honest, and a code is burnt even when the exchange that follows fails.)
  def mcp_oauth_consume_code(code)
    return nil if code.empty?

    key = mcp_oauth_code_key(code)
    blob = mcp_oauth_config.cache_store.read(key)
    return nil if blob.nil?
    return nil unless mcp_oauth_config.cache_store.delete(key)

    mcp_oauth_decrypt_payload(code, blob)
  end

  def mcp_oauth_decrypt_payload(code, blob)
    JSON.parse(mcp_oauth_encryptor(code).decrypt_and_verify(blob), symbolize_names: true)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError
    nil
  end

  def mcp_oauth_code_key(code)
    "#{CODE_CACHE_PREFIX}#{Digest::SHA256.hexdigest(code)}"
  end

  # HMAC because two independent inputs are being combined (why the secret is one
  # of them: Configuration#oauth_signing_secret). No password-stretching — both
  # are already high-entropy, so a PBKDF2 run per request would buy nothing.
  #
  # Cipher and serializer are pinned, not inherited: the gem supports
  # ActiveSupport >= 6.1, where both defaults are Rails-configuration-dependent
  # (`:marshal`, and 7.1+'s `:json_allow_marshal`). The payload is already a JSON
  # String, so NullSerializer costs nothing and leaves JSON.parse the only parser
  # this code hands the plaintext to.
  #
  # It does NOT buy immunity from a writable cache: `Cache::Store` marshals the
  # entry itself, so a store that can be written to is a code-execution problem
  # before anything here is reached. This is determinism across the supported
  # range, not a mitigation.
  def mcp_oauth_encryptor(code)
    key = OpenSSL::HMAC.digest("SHA256", mcp_oauth_signing_secret, "#{CODE_CACHE_PREFIX}key:#{code}")
    ActiveSupport::MessageEncryptor.new(
      key, cipher: "aes-256-gcm", serializer: ActiveSupport::MessageEncryptor::NullSerializer
    )
  end

  def mcp_oauth_signing_secret
    mcp_oauth_config.oauth_signing_secret.tap do |secret|
      raise McpToolkit::Errors::ConfigurationError, "oauth_signing_secret is not configured" if secret.to_s.empty?
    end
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

  # Sets `code` (and echoes `state`) on the client's redirect_uri, preserving any
  # other query it already carries.
  #
  # SETS, not appends: a loopback redirect_uri is not an exact-matched string, so
  # a caller can put `?code=…` in it themselves. Appending would emit
  # `?code=theirs&code=ours` and leave which one wins to the client's parser.
  # Dropping any inbound `code`/`state` keeps the response OAuth-shaped whatever
  # was passed in.
  #
  # The base is taken as the checked string rather than round-tripped through
  # `URI`, so the host part of what is emitted is byte-identical to what the
  # policy approved. The query IS re-encoded (`?a=1?b=2` normalises to
  # `?a=1%3Fb%3D2`), which is the point — that is where `code` gets stripped.
  def mcp_oauth_callback_url(code)
    redirect_uri = params[:redirect_uri].to_s
    base, _, existing = redirect_uri.partition("?")
    pairs = mcp_oauth_preserved_query_pairs(existing)
    pairs << ["code", code]
    pairs << ["state", params[:state].to_s] if params[:state].present?
    "#{base}?#{URI.encode_www_form(pairs)}"
  end

  # A client's own query survives; the two parameters this response owns do not,
  # whoever put them there. The rescue is a backstop, not a designed path: both
  # sanctioned redirect_uris are `URI.parse`d before they reach here, which
  # already refuses what `decode_www_form` would raise on.
  def mcp_oauth_preserved_query_pairs(query)
    return [] if query.empty?

    URI.decode_www_form(query).reject { |pair| RESPONSE_OWNED_QUERY_KEYS.include?(pair.first) }
  rescue ArgumentError
    []
  end

  # ---- responses ------------------------------------------------------------

  # 422 as an integer, not a symbol: the gemspec pins no Rack floor, and neither
  # symbol spans the range it allows — `:unprocessable_content` raises below Rack
  # 3.1, `:unprocessable_entity` is deprecated above it. A symbol that raises here
  # would turn a mistyped paste into an unauthenticated 500 on the one page whose
  # job is to say "that token isn't valid".
  def mcp_oauth_reject_paste
    @mcp_oauth_error = "That access token is not valid, or it has expired or been revoked."
    render :authorize, layout: false, formats: [:html], status: 422
  end

  def mcp_oauth_render_bad_request(message)
    render plain: message, status: :bad_request
  end

  # Applied to the token response, where RFC 6749 §5.1 makes both headers a MUST
  # for anything carrying a token, and to both metadata documents, where the
  # reason is subtler: they name the `authorization_endpoint` an operator will be
  # sent to and are built from the live request origin (`request.base_url`, which
  # honours `X-Forwarded-Host`), so a shared cache that stored one keyed only by
  # path could serve every client an origin an attacker chose — with the document
  # itself vouching for it. A host MUST pin `config.hosts` — Rails'
  # HostAuthorization then rejects a forged header before it reaches here, but
  # Rails does NOT do that for you: `config.hosts` is populated in development and
  # left EMPTY in production, where an empty list means no checking at all. This
  # header is the half that does not depend on the host getting that right.
  def mcp_oauth_forbid_caching
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end

  def mcp_oauth_render_token_error(code)
    render json: { error: code }, status: :bad_request
  end
end
