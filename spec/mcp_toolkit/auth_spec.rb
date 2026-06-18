# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Authentication" do
  let(:central_url) { "https://central.example.com" }
  let(:introspect_endpoint) { "#{central_url}/mcp/tokens/introspect" }

  def configure_satellite!
    McpToolkit.configure do |c|
      c.auth_role = :satellite
      c.central_app_url = central_url
      c.required_application = "notifications"
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
    before { configure_satellite! }

    it "parses a valid response into a Result" do
      stub_introspect(
        token: "good",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42],
                expires_at: nil, applications: ["notifications"] }
      )

      result = described_class.call("good")

      expect(result).to be_valid
      expect(result).to be_accounts_user
      expect(result.account_id).to eq(42)
      expect(result.authorized_for_application?("notifications")).to be(true)
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
        body: { valid: true, kind: "user", account_id: nil, account_ids: [1, 2], applications: ["notifications"] }
      )

      3.times { described_class.call("cached") }

      expect(stub).to have_been_made.once
    end
  end

  describe McpToolkit::Auth::Authenticator do
    before { configure_satellite! }

    it "resolves an accounts_user token to its bound, locally-mapped scope root" do
      stub_introspect(
        token: "au",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], applications: ["notifications"] }
      )

      context = described_class.call(token: "au")

      expect(context.scope_root).to eq(:local_account_42)
    end

    it "rejects a token not scoped to the required application" do
      stub_introspect(
        token: "wrong_app",
        body: { valid: true, kind: "accounts_user", account_id: 42, account_ids: [42], applications: ["other"] }
      )

      expect { described_class.call(token: "wrong_app") }
        .to raise_error(McpToolkit::Errors::Unauthorized, /notifications.*application/)
    end

    it "requires a superuser token to select an authorized account" do
      stub_introspect(
        token: "su",
        body: { valid: true, kind: "user", account_id: nil, account_ids: [42, 99], applications: ["notifications"] }
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
                applications: ["notifications"] }
      )

      expect { described_class.call(token: "no_local") }
        .to raise_error(McpToolkit::Errors::Unauthorized, /no local scope/)
    end
  end

  describe McpToolkit::Auth::Authority do
    # A token object matching the documented duck-typed contract.
    let(:token_class) do
      Struct.new(:kind, :account_id, :account_ids, :expires_at, :application_keys, keyword_init: true) do
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
                              expires_at: nil, application_keys: ["notifications"])
      McpToolkit.configure do |c|
        c.auth_role = :authority
        c.token_authenticator = ->(plaintext) { plaintext == "secret" ? token : nil }
      end

      authenticated = described_class.authenticate("secret")

      expect(authenticated).to eq(token)
      expect(token).to be_touched
      expect(described_class.authenticate("nope")).to be_nil
    end

    it "raises ConfigurationError if no token_authenticator is set" do
      McpToolkit.config.auth_role = :authority
      expect { described_class.authenticate("x") }
        .to raise_error(McpToolkit::Errors::ConfigurationError, /token_authenticator/)
    end

    it "builds the exact introspection payload the satellite parses (accounts_user)" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: Time.utc(2026, 12, 31), application_keys: ["notifications"])

      payload = described_class.introspection_payload(token)

      expect(payload).to eq(
        valid: true,
        kind: "accounts_user",
        account_id: 42,
        account_ids: [42],
        expires_at: "2026-12-31T00:00:00Z",
        applications: ["notifications"]
      )
    end

    it "nulls account_id for a superuser/multi-account token" do
      token = token_class.new(kind: :user, account_id: nil, account_ids: [1, 2],
                              expires_at: nil, application_keys: [])

      payload = described_class.introspection_payload(token)

      expect(payload[:kind]).to eq("user")
      expect(payload[:account_id]).to be_nil
      expect(payload[:account_ids]).to eq([1, 2])
    end

    it "round-trips: an authority payload is consumed by the satellite Introspection parser" do
      token = token_class.new(kind: :accounts_user, account_id: 42, account_ids: [42],
                              expires_at: nil, application_keys: ["notifications"])
      payload = described_class.introspection_payload(token)

      configure_satellite!
      stub_request(:post, introspect_endpoint).to_return(
        status: 200, body: JSON.generate(payload), headers: { "Content-Type" => "application/json" }
      )

      result = McpToolkit::Auth::Introspection.call("forwarded")
      expect(result).to be_valid
      expect(result.account_id).to eq(42)
      expect(result.authorized_for_application?("notifications")).to be(true)
    end
  end
end
