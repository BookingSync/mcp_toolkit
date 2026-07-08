# frozen_string_literal: true

RSpec.describe McpToolkit::Resource do
  describe "#filterable with a lazy (callable) source" do
    it "does NOT invoke the callable at registration; resolves it once on first read, then memoizes" do
      calls = 0
      resource = described_class.new("widgets")

      resource.filterable(lambda {
        calls += 1
        { color: :color, size: :size_cm }
      })

      # Registration-time: the callable must not run (it may touch the DB, which is
      # unavailable while an initializer's to_prepare runs — e.g. CI's db:create).
      expect(calls).to eq(0)

      expect(resource.filterable_columns).to eq(color: :color, size: :size_cm)
      expect(resource.filterable_keys).to eq(%i[color size])

      # Resolved exactly once, then cached.
      expect(calls).to eq(1)
    end

    it "still accepts a plain Hash (merged eagerly, no source)" do
      resource = described_class.new("widgets")
      resource.filterable(color: :color)

      expect(resource.filterable_columns).to eq(color: :color)
      expect(resource.filterable_keys).to eq(%i[color])
    end

    it "tolerates a callable returning nil (treated as an empty map)" do
      resource = described_class.new("widgets")
      resource.filterable(-> {})

      expect(resource.filterable_columns).to eq({})
    end
  end
end
