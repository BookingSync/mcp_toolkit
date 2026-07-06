# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::Authority::Context do
  let(:account) { FakeAccount.new(1) }

  describe "#superuser?" do
    it "uses config.superuser_resolver when one is set" do
      McpToolkit.config.superuser_resolver = ->(principal) { principal == :the_boss }

      expect(described_class.new(account:, principal: :the_boss).superuser?).to be(true)
      expect(described_class.new(account:, principal: :nobody).superuser?).to be(false)
    end

    it "falls back to duck-typing principal.superuser? when no resolver is set" do
      expect(described_class.new(account:, principal: FakePrincipal.new(superuser: true)).superuser?).to be(true)
      expect(described_class.new(account:, principal: FakePrincipal.new(superuser: false)).superuser?).to be(false)
    end

    it "is false when neither a resolver nor a superuser-aware principal is present" do
      not_superuser_aware = Object.new

      expect(described_class.new(account:, principal: not_superuser_aware).superuser?).to be(false)
      expect(described_class.new(account:, principal: nil).superuser?).to be(false)
    end
  end
end
