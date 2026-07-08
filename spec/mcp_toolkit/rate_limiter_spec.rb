# frozen_string_literal: true

require "spec_helper"

# Drives the fixed-window counter against a REAL ActiveSupport::Cache::MemoryStore
# (the same contract a Rails.cache satisfies), pinning `now` to exercise window
# rollover deterministically.
RSpec.describe McpToolkit::RateLimiter do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  def limiter(key: "p1", max_requests: 3, window: 3600, now: Time.now)
    described_class.new(key:, max_requests:, window:, cache_store:, now:)
  end

  describe "#call" do
    it "allows requests up to the limit, reporting the decreasing remaining count" do
      results = Array.new(3) { limiter.call }

      expect(results.map(&:allowed?)).to eq([true, true, true])
      expect(results.map(&:remaining)).to eq([2, 1, 0])
      expect(results.map(&:limit)).to eq([3, 3, 3])
    end

    it "blocks once the count exceeds the limit, with remaining floored at 0" do
      3.times { limiter.call }

      result = limiter.call

      expect(result).not_to be_allowed
      expect(result.remaining).to eq(0)
    end

    it "counts per fixed window: a fresh window resets the counter" do
      base = Time.now.to_i
      window_start = base - (base % 3600)
      3.times { limiter(now: window_start + 10).call }

      # Same window: still over the limit.
      expect(limiter(now: window_start + 20).call).not_to be_allowed
      # Next window: a brand-new counter allows again.
      expect(limiter(now: window_start + 3600).call).to be_allowed
    end

    it "counts each key independently" do
      3.times { limiter(key: "a").call }

      expect(limiter(key: "a").call).not_to be_allowed
      expect(limiter(key: "b").call).to be_allowed
    end

    it "reports reset_at at the next window boundary and retry_after until then" do
      base = Time.now.to_i
      window_start = base - (base % 3600)

      result = limiter(now: base).call

      expect(result.reset_at).to eq(window_start + 3600)
      expect(result.retry_after).to eq(window_start + 3600 - base)
    end
  end
end
