# frozen_string_literal: true

# Namespace for the OAuth authorization bridge (McpToolkit::Oauth::ControllerMethods),
# and the home of the one policy value both the request path and the config path
# need to agree on.
module McpToolkit::Oauth
  # RFC 8252 §7.3 loopback hosts — the only hosts a code may be sent to over
  # cleartext, and the only redirect target accepted without being named. The RFC
  # prefers the IP literals over the name (a name is only as trustworthy as the
  # resolver — §8.3), but real clients use all three, and RFC 6761 has OS
  # resolvers and browsers hardcode `localhost` to loopback.
  #
  # Lives here rather than on the concern because Configuration reads it too, to
  # decide whether an allowlisted `http://` entry is a mistake: cleartext is fine
  # to an address that never leaves the operator's machine, and puts the code on
  # the wire anywhere else. One list, so the two paths cannot drift apart.
  LOOPBACK_HOSTS = ["127.0.0.1", "::1", "localhost"].freeze

  # `[::1]` arrives bracketed from `URI`; compare against the bare form.
  def self.loopback_host?(host)
    LOOPBACK_HOSTS.include?(host.to_s.downcase.delete_prefix("[").delete_suffix("]"))
  end
end
