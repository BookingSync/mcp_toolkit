# frozen_string_literal: true

# A fixed-window request counter backing the authority transport's built-in rate
# limiting (McpToolkit::Authority::ControllerMethods#mcp_rate_limit!). It is
# storage-agnostic: it counts against the injected `cache_store` (any
# ActiveSupport::Cache::Store — a shared Rails.cache in production, a MemoryStore
# in a unit test), so a host enables per-principal throttling by setting
# `config.rate_limit_max_requests` alone, without hand-rolling a limiter.
#
# The window is FIXED, not sliding: every request whose time falls in the same
# `window`-second bucket shares one counter, keyed by that bucket's start
# (`window_start`); the entry expires after `window` seconds. The counter is
# incremented once per call, and the request is allowed while the running count is
# `<= max_requests`, blocked once it exceeds it (so exactly `max_requests`
# requests pass per window).
#
#   result = McpToolkit::RateLimiter.new(
#     key: principal.id, max_requests: 1_000, window: 3_600, cache_store: Rails.cache
#   ).call
#   result.allowed?     # => false once the count exceeds max_requests
#   result.limit        # => 1_000
#   result.remaining    # => max_requests - count, floored at 0
#   result.reset_at     # => epoch seconds of the next window boundary
#   result.retry_after  # => seconds until reset_at (0 when already past)
#
# The cache key is namespaced (`mcp_toolkit:rate_limit:<key>:<window_start>`) so a
# host's own cache entries never collide with the counter.
class McpToolkit::RateLimiter
  # The outcome of one #call: the throttling decision plus the values the
  # transport renders into the `X-RateLimit-*` / `Retry-After` headers.
  Result = Struct.new(:allowed, :limit, :remaining, :reset_at, :retry_after, keyword_init: true) do
    def allowed?
      allowed
    end
  end

  def initialize(key:, max_requests:, cache_store:, window: 3_600, now: Time.now)
    @key = key
    @max_requests = max_requests
    @cache_store = cache_store
    @window = window
    @now = now.to_i
  end

  # Increments this window's counter and returns the Result. Called once per
  # request by the transport's rate-limit hook.
  def call
    count = @cache_store.increment(cache_key, 1, expires_in: @window) || 1
    allowed = count <= @max_requests

    Result.new(
      allowed:,
      limit: @max_requests,
      remaining: allowed ? @max_requests - count : 0,
      reset_at:,
      retry_after: [reset_at - @now, 0].max
    )
  end

  private

  def window_start
    @now - (@now % @window)
  end

  def reset_at
    window_start + @window
  end

  def cache_key
    "mcp_toolkit:rate_limit:#{@key}:#{window_start}"
  end
end
