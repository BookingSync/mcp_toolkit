# frozen_string_literal: true

# Generic, api-agnostic usage metering for the AUTHORITY transport.
#
# Wired to the authority controller's billing hooks purely through config, so a
# host meters MCP traffic WITHOUT subclassing or customizing the controller:
#
#   meter = McpToolkit::UsageMetering::Recorder.new(
#     event_builder:    ->(request_data:, params:, arguments:, scrubbed_arguments:, account:, principal:) { {...} },
#     sink:             ->(events) { MyLedger.insert_all(events) },
#     parameter_filter: ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters),
#     logger:           Rails.logger,
#     error_reporter:   ->(e) { Sentry.capture_exception(e) }
#   )
#   config.usage_recorder = meter.method(:record)   # per JSON-RPC call
#   config.usage_flusher  = meter.method(:flush)    # after the response
#
# One event is accumulated per BILLABLE JSON-RPC call (default: `tools/call`) and
# all of a request's events are flushed together after the response. Because the
# authority transport re-resolves the account per batch element and calls `record`
# per element, a mixed-account batch meters each call against its own account.
#
# Two invariants:
#   * Metering NEVER affects the MCP response — every error here is logged (via
#     `logger`) and reported (via `error_reporter`), then swallowed.
#   * The raw arguments are scrubbed through `parameter_filter` BEFORE they reach
#     the event, so a filtered key (e.g. a token) never leaves this object.
#
# The `event_builder` returns ONE ledger row's attributes (a Hash) for a call, or
# nil to skip it; the gem stays app-agnostic by never naming the row's columns. The
# `sink` persists the accumulated array in one shot.
#
# Per-request state (the accumulation buffer) lives on the Rack request env, so the
# Recorder itself is stateless and safe to share across requests/threads.
class McpToolkit::UsageMetering::Recorder
  DEFAULT_BILLABLE_METHODS = %w[tools/call].freeze
  BUFFER_ENV_KEY = "mcp_toolkit.usage_events"

  def initialize(event_builder:, sink:, parameter_filter: nil,
                 billable_methods: DEFAULT_BILLABLE_METHODS, logger: nil, error_reporter: nil)
    @event_builder = event_builder
    @sink = sink
    @parameter_filter = parameter_filter
    @billable_methods = billable_methods
    @logger = logger
    @error_reporter = error_reporter
  end

  # `config.usage_recorder` target. Accumulates one event for a billable call onto
  # the current request's buffer. Non-billable methods (ping, initialize,
  # tools/list, ...) are ignored; a nil event from the builder is skipped.
  def record(request_data:, account:, principal:, controller:)
    return unless request_data.is_a?(Hash)
    return unless @billable_methods.include?(request_data["method"])

    params = request_data["params"].to_h
    arguments = params["arguments"].to_h
    event = @event_builder.call(
      request_data:, params:, arguments:,
      scrubbed_arguments: scrub(arguments), account:, principal:
    )
    buffer_for(controller) << event unless event.nil?
  rescue StandardError => e
    report("failed to accumulate event", e)
  end

  # `config.usage_flusher` target. Persists the request's accumulated events via the
  # sink in one shot. No-op when nothing was accumulated.
  def flush(controller:)
    events = buffer_for(controller)
    return if events.empty?

    @sink.call(events)
  rescue StandardError => e
    report("failed to flush #{events&.size} event(s)", e)
  end

  private

  def scrub(arguments)
    hash = arguments.to_h
    @parameter_filter ? @parameter_filter.filter(hash) : hash
  end

  # Per-request accumulation buffer, stored on the Rack env so the Recorder holds
  # no per-request state of its own (thread-safe to share across requests).
  def buffer_for(controller)
    controller.request.env[BUFFER_ENV_KEY] ||= []
  end

  def report(message, error)
    @logger&.warn("MCP usage tracking: #{message}: #{error.message}")
    @error_reporter&.call(error)
  end
end
