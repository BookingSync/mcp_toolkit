# frozen_string_literal: true

require "spec_helper"

RSpec.describe McpToolkit::UnknownResourceMessage do
  def build(name, resource_names)
    described_class.new(name, resource_names).build
  end

  it "states the bad name alone when the registry is empty" do
    expect(build("widgets", [])).to eq('unknown resource: "widgets"')
  end

  it "suggests the nearest registered name on a near-miss" do
    expect(build("widget", %w[widgets gadgets])).to include('Did you mean "widgets"?')
  end

  it "lists all registered names, sorted, when the catalog is short" do
    expect(build("zzz", %w[widgets gadgets])).to include('Registered resources: "gadgets", "widgets".')
  end

  it "neither suggests nor lists for a large catalog with no near-miss" do
    resource_names = (1..12).map { |n| "resource_#{n}" }

    message = build("zzzzz", resource_names)

    expect(message).to eq('unknown resource: "zzzzz"')
    expect(message).not_to include("Registered resources:")
    expect(message).not_to include("Did you mean")
  end

  it "finds a near-miss via the dependency-free edit-distance fallback" do
    resource_names = %w[notifications scheduled_notifications]
    message = described_class.new("notification", resource_names)

    expect(message.send(:fallback_suggestions, "notification", resource_names)).to include("notifications")
  end
end
