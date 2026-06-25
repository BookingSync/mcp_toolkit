# frozen_string_literal: true

require "spec_helper"
# This spec raises Faraday::ConnectionFailed directly (the unreachable-central
# case). faraday is required lazily by Auth::AuthorityServerClient, which isn't
# guaranteed to have loaded before this file runs under a randomized order, so
# require it here where the constant is referenced.
require "faraday"

RSpec.describe "Authentication" do
  let(:central_url) { "https://central.example.com" }
  let(:introspect_endpoint) { "#{central_url}/mcp/tokens/introspect" }

  def configure_satellite!
    McpToolkit.configure do |c|
      c.auth_role = :satellite
      c.central_app_url = central_url
      c.registry.default_required_permissions_scope "notifications__read"
      c.introspection_cache_ttl = 0 # don't let cache mask repeated stubs in tests
      # Map the central account id to a local "scope root" object.
      c.account_resolver = ->(synced_id) { synced_id == 42 ? :local_account_42 : nil }
    end
  end

  def stub_introspect(token:, body:, status: 200)
    stub_request(:post, introspect_endpoint)
      .with(headers: { "Authorization" => "Bearer #{token}" })
      .to_return(status:, body: JSON.generate(body), headers: { "Content-Type" => "application/json" })
  end

  describe McpToolkit::Auth::Introspection do
    # The canonical introspection of a valid accounts_user token; examples that
    # need other shapes call described_class.call with their own token/stub.
    subject(:introspection_result) { described_class.call("good") }

    before { configure_satellite! }

    it "parses a valid response into a Result" do
      stub_introspect(
        token: "good",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                expires_at: nil, scopes: ["notifications__read"] }
      )

      expect(introspection_result).to be_valid
      expect(introspection_result).to be_accounts_user
      expect(introspection_result.account_id).to eq(42)
      expect(introspection_result.scopes).to eq(["notifications__read"])
      expect(introspection_result.authorized_for_scope?("notifications__read")).to be(true)
    end

    it "derives per-scope authorization purely from scopes" do
      stub_introspect(
        token: "scoped",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                expires_at: nil, scopes: ["notifications__read"] }
      )

      result = described_class.call("scoped")

      # exact scope present
      expect(result.authorized_for_scope?("notifications__read")).to be(true)
      # exact scope absent (different action)
      expect(result.authorized_for_scope?("notifications__write")).to be(false)
      # exact scope absent (different app)
      expect(result.authorized_for_scope?("billing__read")).to be(false)
    end

    it "allows a tool that requires NO scope when token scopes are empty" do
      stub_introspect(
        token: "no_scopes",
        body: { valid: true, kind: "user", account_id: nil, account_ids: [1], expires_at: nil, scopes: [] }
      )

      result = described_class.call("no_scopes")

      # A tool requiring no scope (empty required scope) is reachable by any valid token.
      expect(result.authorized_for_scope?("")).to be(true)
      expect(result.authorized_for_scope?(nil)).to be(true)
    end

    it "does NOT allow a tool that requires SOME scope when token scopes are empty" do
      stub_introspect(
        token: "no_scopes",
        body: { valid: true, kind: "user", account_id: nil, account_ids: [1], expires_at: nil, scopes: [] }
      )

      result = described_class.call("no_scopes")

      # Empty token scopes is unrestricted ONLY for tools that require no scope:
      # a tool requiring a scope is NOT reachable.
      expect(result.authorized_for_scope?("anything__read")).to be(false)
    end

    it "allows iff the required scope is present in the token's scopes" do
      stub_introspect(
        token: "mixed",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                expires_at: nil, scopes: %w[notifications__read billing__read] }
      )

      result = described_class.call("mixed")

      # required scope present -> allowed
      expect(result.authorized_for_scope?("notifications__read")).to be(true)
      expect(result.authorized_for_scope?("billing__read")).to be(true)
      # required scope absent -> not allowed
      expect(result.authorized_for_scope?("notifications__write")).to be(false)
      expect(result.authorized_for_scope?("other__read")).to be(false)
    end

    it "treats an empty required scope as authorized regardless of token scopes" do
      result = McpToolkit::Auth::Introspection::Result.new(valid: true, scopes: ["notifications__read"])

      expect(result.authorized_for_scope?("")).to be(true)
      expect(result.authorized_for_scope?(nil)).to be(true)
    end

    describe "local expiry enforcement (defense-in-depth)" do
      it "rejects a valid:true token whose expires_at is in the past" do
        stub_introspect(
          token: "lapsed",
          body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                  expires_at: (Time.now - 3600).utc.iso8601, scopes: ["notifications__read"] }
        )

        result = described_class.call("lapsed")

        expect(result).not_to be_valid
        expect(result).to be_expired
      end

      it "accepts a valid:true token whose expires_at is in the future" do
        stub_introspect(
          token: "fresh",
          body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                  expires_at: (Time.now + 3600).utc.iso8601, scopes: ["notifications__read"] }
        )

        result = described_class.call("fresh")

        expect(result).to be_valid
        expect(result).not_to be_expired
      end

      it "treats a nil/absent expires_at as a token with no expiry (valid)" do
        stub_introspect(
          token: "no_expiry",
          body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                  expires_at: nil, scopes: ["notifications__read"] }
        )

        result = described_class.call("no_expiry")

        expect(result).to be_valid
        expect(result).not_to be_expired
      end

      it "treats an unparseable expires_at as expired (fail-closed)" do
        stub_introspect(
          token: "garbage_expiry",
          body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                  expires_at: "not-a-timestamp", scopes: ["notifications__read"] }
        )

        result = described_class.call("garbage_expiry")

        expect(result).to be_expired
        expect(result).not_to be_valid
      end

      it "expires a cached Result the moment it lapses (evaluated at check time)" do
        result = McpToolkit::Auth::Introspection::Result.new(
          valid: true, expires_at: (Time.now - 1).utc.iso8601, scopes: ["notifications__read"]
        )

        expect(result).to be_expired
        expect(result).not_to be_valid
      end
    end

    it "returns INVALID on a 401 from the central app" do
      stub_introspect(token: "bad", status: 401, body: { valid: false })

      expect(described_class.call("bad")).not_to be_valid
    end

    it "returns INVALID (never raises) when the central app is unreachable" do
      stub_request(:post, introspect_endpoint).to_raise(Faraday::ConnectionFailed.new("boom"))

      expect(described_class.call("any")).not_to be_valid
    end

    it "treats a blank token as invalid without hitting the network" do
      expect(described_class.call("")).not_to be_valid
      expect(a_request(:post, introspect_endpoint)).not_to have_been_made
    end

    it "caches results so a burst of calls makes a single HTTP request" do
      McpToolkit.config.introspection_cache_ttl = 60
      stub = stub_introspect(
        token: "cached",
        body: { valid: true, kind: "user", account_id: nil, account_ids: [1, 2], scopes: ["notifications__read"] }
      )

      3.times { described_class.call("cached") }

      expect(stub).to have_been_made.once
    end
  end

  describe McpToolkit::Auth::Authenticator do
    # The canonical resolution of an accounts_user token; examples that exercise
    # superuser / mismatch paths call described_class.call with their own args.
    subject(:authenticated_context) { described_class.call(token: "au") }

    before { configure_satellite! }

    it "resolves an accounts_user token to its bound, locally-mapped scope root" do
      stub_introspect(
        token: "au",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["notifications__read"] }
      )

      expect(authenticated_context.scope_root).to eq(:local_account_42)
    end

    it "resolves any valid token regardless of scope (scope enforcement lives at the tool layer)" do
      # The authenticator only validates the token + resolves the tenant; the exact
      # `<app>__<action>` scope is enforced by Tools::Base#with_account. A token
      # carrying a different app's scope still resolves here...
      stub_introspect(
        token: "other_app",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], scopes: ["other__read"] }
      )

      context = described_class.call(token: "other_app")

      expect(context.scope_root).to eq(:local_account_42)
      # ...but it does NOT carry the notifications scope a tool would require.
      expect(context.introspection.authorized_for_scope?("notifications__read")).to be(false)
    end

    it "requires a superuser token to select an authorized account" do
      stub_introspect(
        token: "su",
        body: { valid: true, kind: "user", account_id: nil, account_ids: [42, 99], scopes: ["notifications__read"] }
      )

      # No selector -> rejected
      expect { described_class.call(token: "su") }
        .to raise_error(McpToolkit::Errors::Unauthorized, /multiple accounts/)

      # Selector for an authorized account -> resolves
      context = described_class.call(token: "su", arguments: { "account_id" => 42 })
      expect(context.scope_root).to eq(:local_account_42)

      # Selector for an unauthorized account -> rejected
      expect { described_class.call(token: "su", arguments: { "account_id" => 7 }) }
        .to raise_error(McpToolkit::Errors::Unauthorized, /not authorized/)
    end

    it "rejects when no local scope maps to the resolved account" do
      stub_introspect(
        token: "no_local",
        body: { valid: true, kind: "accounts_user", account_id: 999, account_ids: [999],
                scopes: ["notifications__read"] }
      )

      expect { described_class.call(token: "no_local") }
        .to raise_error(McpToolkit::Errors::Unauthorized, /no local scope/)
    end
  end

  describe McpToolkit::Auth::Authority do
    # The authority module under test (a collection of module-level helpers).
    subject(:authority) { described_class }

    # A token object matching the documented duck-typed contract.
    let(:token_class) do
      Struct.new(:kind, :account_id, :account_ids, :expires_at, :scopes, keyword_init: true) do
        def touch_last_used!
          @touched = true
        end

        def touched?
          @touched == true
        end
      end
    end

    it "authenticates a plaintext token via the configured authenticator and touches last-used" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: nil, scopes: ["notifications__read"])
      McpToolkit.configure do |c|
        c.auth_role = :authority
        c.token_authenticator = ->(plaintext) { plaintext == "secret" ? token : nil }
      end

      authenticated = authority.authenticate("secret")

      expect(authenticated).to eq(token)
      expect(token).to be_touched
      expect(authority.authenticate("nope")).to be_nil
    end

    it "raises ConfigurationError if no token_authenticator is set" do
      McpToolkit.config.auth_role = :authority
      expect { authority.authenticate("x") }
        .to raise_error(McpToolkit::Errors::ConfigurationError, /token_authenticator/)
    end

    it "builds the exact introspection payload the satellite parses (accounts_user)" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: Time.utc(2026, 12, 31), scopes: ["notifications__read"])

      payload = authority.introspection_payload(token)

      expect(payload).to eq(
        valid: true,
        kind: "accounts_user",
        account_id: 42,
        account_ids: [42],
        expires_at: "2026-12-31T00:00:00Z",
        scopes: ["notifications__read"]
      )
    end

    it "does not emit an applications field (authorization is scope-only)" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: nil, scopes: ["notifications__read"])

      expect(authority.introspection_payload(token)).not_to have_key(:applications)
    end

    it "nulls account_id for a superuser/multi-account token" do
      token = token_class.new(kind: :user, account_id: nil, account_ids: [1, 2],
                              expires_at: nil, scopes: [])

      payload = authority.introspection_payload(token)

      expect(payload[:kind]).to eq("user")
      expect(payload[:account_id]).to be_nil
      expect(payload[:account_ids]).to eq([1, 2])
      expect(payload[:scopes]).to eq([])
    end

    it "wraps token scopes with Array (nil scopes => [])" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: nil, scopes: nil)

      expect(authority.introspection_payload(token)[:scopes]).to eq([])
    end

    it "round-trips: an authority payload is consumed by the satellite Introspection parser" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: nil, scopes: ["notifications__read"])
      payload = authority.introspection_payload(token)

      configure_satellite!
      stub_request(:post, introspect_endpoint).to_return(
        status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" }
      )

      result = McpToolkit::Auth::Introspection.call("forwarded")
      expect(result).to be_valid
      expect(result.account_id).to eq(42)
      expect(result.authorized_for_scope?("notifications__read")).to be(true)
    end
  end
end
