# frozen_string_literal: true

require "spec_helper"

# The gem suite runs WITHOUT ActiveRecord, so this drives the concern's api-agnostic
# contract against a minimal host class that provides only the AR class-macro seams
# its `included do` block touches (validates / before_validation / scope as no-ops)
# plus plain attribute accessors. The AR-integrated behavior (`.authenticate`, the
# lifecycle scopes, `#touch_last_used!` persistence) is covered end-to-end by the
# host app's model spec.
RSpec.describe McpToolkit::Authority::Token do
  let(:token_class) do
    Class.new do
      def self.validates(*); end
      def self.before_validation(*); end
      def self.scope(*); end

      include McpToolkit::Authority::Token

      attr_accessor :token_digest, :token_prefix, :scopes, :expires_at, :last_used_at

      def initialize(**attrs)
        attrs.each { |key, value| public_send("#{key}=", value) }
      end
    end
  end

  describe "constants" do
    it "exposes the generic plaintext layout" do
      expect(described_class::TOKEN_PREFIX).to eq("mcp_")
      expect(described_class::RAW_TOKEN_BYTES).to eq(24)
      expect(described_class::TOKEN_PREFIX_DISPLAY_LENGTH).to eq(11)
    end
  end

  describe ".digest_for" do
    it "is a plain SHA256 of the plaintext" do
      expect(token_class.digest_for("mcp_known")).to eq(Digest::SHA256.hexdigest("mcp_known"))
    end
  end

  describe "#assign_token (generation on create)" do
    it "generates a prefixed plaintext, its digest, and the display prefix" do
      token = token_class.new
      token.send(:assign_token)

      expect(token.token).to start_with("mcp_")
      expect(token.token_digest).to eq(token_class.digest_for(token.token))
      expect(token.token_prefix).to eq(token.token[0, 11])
      expect(token.token_prefix.length).to eq(described_class::TOKEN_PREFIX_DISPLAY_LENGTH)
    end

    it "is a no-op when a digest is already present (never regenerates)" do
      token = token_class.new(token_digest: "existing")
      token.send(:assign_token)

      expect(token.token).to be_nil
      expect(token.token_digest).to eq("existing")
    end
  end

  describe "#normalized_scopes" do
    it "returns [] for a NULL/empty scope column" do
      expect(token_class.new(scopes: nil).normalized_scopes).to eq([])
      expect(token_class.new(scopes: []).normalized_scopes).to eq([])
    end

    it "drops blank entries" do
      expect(token_class.new(scopes: ["notifications__read", "", " "]).normalized_scopes)
        .to eq(["notifications__read"])
    end
  end

  describe "#authorized_for_scope?" do
    it "lets any token reach a no-scope tool" do
      expect(token_class.new(scopes: nil).authorized_for_scope?(nil)).to be(true)
      expect(token_class.new(scopes: ["x"]).authorized_for_scope?("")).to be(true)
    end

    it "requires the token to hold the exact scope for a scoped tool" do
      token = token_class.new(scopes: ["notifications__read"])
      expect(token.authorized_for_scope?("notifications__read")).to be(true)
      expect(token.authorized_for_scope?("owners__read")).to be(false)
    end

    it "an unrestricted token holds no scopes, so it can reach only no-scope tools" do
      unrestricted = token_class.new(scopes: nil)
      expect(unrestricted.authorized_for_scope?("notifications__read")).to be(false)
    end
  end

  describe "#scope_restricted?" do
    it "is false for an unrestricted token and true once a scope is set" do
      expect(token_class.new(scopes: nil).scope_restricted?).to be(false)
      expect(token_class.new(scopes: ["notifications__read"]).scope_restricted?).to be(true)
    end
  end
end
