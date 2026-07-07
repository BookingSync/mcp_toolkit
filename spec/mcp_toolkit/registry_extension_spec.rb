# frozen_string_literal: true

require "spec_helper"

# The host-extras seam: a `resource_extension` module adds a host DSL to each
# Resource, and a `resource_finalizer` derives gem-native fields from the extras
# after the block — so a host declares resources DIRECTLY against the gem registry
# instead of maintaining a parallel registration system.
RSpec.describe McpToolkit::Registry do
  subject(:registry) { described_class.new }

  # A host DSL word that stores into the generic Resource#extra bag.
  let(:extension) do
    Module.new do
      def dependencies(*models)
        return Array(extra(:dependencies)) if models.empty?

        extra(:dependencies, models.flatten)
      end
    end
  end

  describe "Resource#extra" do
    let(:resource) { McpToolkit::Resource.new(:things) }

    it "reads nil for an unset key and round-trips a written value (including nil)" do
      expect(resource.extra(:missing)).to be_nil

      resource.extra(:deps, %i[a b])
      expect(resource.extra(:deps)).to eq(%i[a b])

      resource.extra(:explicit_nil, nil)
      expect(resource.extras).to include(explicit_nil: nil)
    end
  end

  describe "#register with a resource_extension" do
    it "makes the extension DSL callable inside the registration block" do
      registry.resource_extension = extension

      registry.register(:bookings) do
        model Hash
        dependencies :rental, :client
      end

      expect(registry.find("bookings").extra(:dependencies)).to eq(%i[rental client])
    end
  end

  describe "#register with a resource_finalizer" do
    it "runs the finalizer against the resource after its block, deriving gem-native fields" do
      registry.resource_extension = extension
      finalized = []
      registry.resource_finalizer = lambda do |resource|
        finalized << resource.name
        resource.description("auto: #{resource.extra(:dependencies).inspect}")
      end

      registry.register(:bookings) do
        model Hash
        dependencies :rental
      end

      expect(finalized).to eq(["bookings"])
      expect(registry.find("bookings").description).to eq("auto: [:rental]")
    end

    it "leaves registration unchanged when neither hook is set" do
      registry.register(:plain) { model Hash }

      expect(registry.find("plain").model).to eq(Hash)
    end
  end

  describe "#reset!" do
    it "preserves resource_extension + resource_finalizer (declared once in configure)" do
      registry.resource_extension = extension
      finalizer = ->(_resource) {}
      registry.resource_finalizer = finalizer
      registry.register(:bookings) { model Hash }

      registry.reset!

      expect(registry.resources).to be_empty
      expect(registry.resource_extension).to be(extension)
      expect(registry.resource_finalizer).to be(finalizer)
    end
  end
end
