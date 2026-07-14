# frozen_string_literal: true

require "spec_helper"
require "active_support/parameter_filter"

RSpec.describe McpToolkit::UsageMetering::Recorder do
  # A minimal stand-in for the authority controller: the Recorder only touches
  # `controller.request.env` (its per-request accumulation buffer).
  let(:controller) do
    env = {}
    request = Struct.new(:env).new(env)
    Struct.new(:request).new(request)
  end

  # Echoes the pieces the transport hands the builder, so each example can assert
  # exactly what was captured (and that scrubbing already happened upstream).
  let(:event_builder) do
    lambda do |request_data:, params:, arguments:, scrubbed_arguments:, account:, principal:|
      {
        method: request_data["method"],
        tool: params["name"],
        arguments: scrubbed_arguments,
        account_id: account&.id,
        principal_id: principal&.id
      }
    end
  end

  let(:flushed) { [] }
  let(:sink) { ->(events) { flushed.replace(events) } }
  let(:principal) { Struct.new(:id).new(7) }
  let(:account) { Struct.new(:id).new(42) }

  subject(:recorder) { described_class.new(event_builder:, sink:) }

  def tools_call(name: "api_v3_list", arguments: { "resource" => "bookings" })
    { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => { "name" => name, "arguments" => arguments } }
  end

  describe "#record" do
    it "accumulates one event per billable call onto the request buffer" do
      recorder.record(request_data: tools_call, account:, principal:, controller:)

      buffer = controller.request.env[described_class::BUFFER_ENV_KEY]
      expect(buffer.size).to eq(1)
      expect(buffer.first).to include(method: "tools/call", tool: "api_v3_list", account_id: 42, principal_id: 7)
    end

    it "ignores non-billable methods (ping, initialize, tools/list)" do
      %w[ping initialize tools/list].each do |method|
        recorder.record(request_data: { "method" => method }, account:, principal:, controller:)
      end

      expect(controller.request.env[described_class::BUFFER_ENV_KEY]).to be_nil
    end

    it "skips a nil event returned by the builder" do
      recorder = described_class.new(event_builder: ->(**) {}, sink:)

      recorder.record(request_data: tools_call, account:, principal:, controller:)

      expect(controller.request.env[described_class::BUFFER_ENV_KEY] || []).to be_empty
    end

    it "accumulates one event per call across a batch (mixed accounts kept distinct)" do
      account_b = Struct.new(:id).new(99)
      recorder.record(request_data: tools_call(arguments: { "resource" => "bookings" }), account:, principal:, controller:)
      recorder.record(request_data: tools_call(arguments: { "resource" => "rentals" }), account: account_b, principal:,
        controller:)

      expect(controller.request.env[described_class::BUFFER_ENV_KEY].map { |e| e[:account_id] }).to eq([42, 99])
    end

    context "with a parameter_filter" do
      subject(:recorder) { described_class.new(event_builder:, sink:, parameter_filter:) }

      let(:parameter_filter) { ActiveSupport::ParameterFilter.new([:token]) }

      it "scrubs the arguments before they reach the builder" do
        recorder.record(request_data: tools_call(arguments: { "resource" => "bookings", "token" => "mcp_secret" }),
          account:, principal:, controller:)

        expect(controller.request.env[described_class::BUFFER_ENV_KEY].first[:arguments])
          .to eq("resource" => "bookings", "token" => "[FILTERED]")
      end
    end

    it "swallows + reports a builder error without touching the buffer" do
      reported = []
      logger = instance_double(Logger, warn: nil)
      recorder = described_class.new(
        event_builder: ->(**) { raise "boom" }, sink:, logger:, error_reporter: ->(e) { reported << e }
      )

      expect { recorder.record(request_data: tools_call, account:, principal:, controller:) }.not_to raise_error
      expect(reported.map(&:message)).to eq(["boom"])
      expect(logger).to have_received(:warn).with(/MCP usage tracking/)
    end
  end

  describe "#flush" do
    it "persists the accumulated events via the sink in one call" do
      recorder.record(request_data: tools_call, account:, principal:, controller:)
      recorder.flush(controller:)

      expect(flushed.size).to eq(1)
      expect(flushed.first).to include(tool: "api_v3_list")
    end

    it "is a no-op when nothing was accumulated" do
      called = false
      recorder = described_class.new(event_builder:, sink: ->(_) { called = true })

      recorder.flush(controller:)

      expect(called).to be(false)
    end

    it "reports the dropped event and never affects the response when the sink keeps failing" do
      reported = []
      logger = instance_double(Logger, warn: nil)
      recorder = described_class.new(
        event_builder:, sink: ->(_) { raise "sink down" }, logger:, error_reporter: ->(e) { reported << e }
      )
      recorder.record(request_data: tools_call, account:, principal:, controller:)

      expect { recorder.flush(controller:) }.not_to raise_error
      expect(reported.map(&:message)).to eq(["sink down"])
      expect(logger).to have_received(:warn).with(/MCP usage tracking/).at_least(:once)
    end

    it "falls back to per-event writes so a batch failure still persists the good events" do
      persisted = []
      sink = lambda do |events|
        raise "batch too big" if events.size > 1

        persisted.concat(events)
      end
      recorder = described_class.new(event_builder:, sink:)
      recorder.record(request_data: tools_call(arguments: { "resource" => "bookings" }), account:, principal:, controller:)
      recorder.record(request_data: tools_call(arguments: { "resource" => "rentals" }), account:, principal:, controller:)

      recorder.flush(controller:)

      expect(persisted.map { |e| e[:arguments] }).to eq([{ "resource" => "bookings" }, { "resource" => "rentals" }])
    end

    it "isolates a single poison event: siblings persist, only the poison one is dropped + reported" do
      reported = []
      persisted = []
      sink = lambda do |events|
        raise "constraint" if events.any? { |e| e[:tool] == "poison" }

        persisted.concat(events)
      end
      recorder = described_class.new(event_builder:, sink:, error_reporter: ->(e) { reported << e })
      recorder.record(request_data: tools_call(name: "good"), account:, principal:, controller:)
      recorder.record(request_data: tools_call(name: "poison"), account:, principal:, controller:)

      recorder.flush(controller:)

      expect(persisted.map { |e| e[:tool] }).to eq(["good"])
      expect(reported.map(&:message)).to eq(["constraint"])
    end
  end
end
