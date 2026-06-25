# frozen_string_literal: true

require "spec_helper"

# Compact (`class McpToolkit::Foo::Bar`) declarations only autoload cleanly when
# every parent namespace is itself reachable through Zeitwerk. Eager-loading the
# whole tree surfaces any namespace that isn't (it would raise
# `NameError: uninitialized constant`), so this guards the flat-declaration +
# split-file layout against regressions.
RSpec.describe "Zeitwerk eager loading" do
  subject(:eager_load) { -> { Zeitwerk::Registry.loaders.each(&:eager_load) } }

  it "loads the entire gem tree without error" do
    expect(&eager_load).not_to raise_error
  end
end
