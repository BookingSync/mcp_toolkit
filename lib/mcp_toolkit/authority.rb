# frozen_string_literal: true

# Namespace for the AUTHORITY-side building blocks: the per-request Context, the
# transport concern (Authority::ControllerMethods), and the lazily-parented base
# controller (Authority::ServerController).
#
# `ServerController` is NOT a file under this directory: like the engine's
# controllers, it subclasses a host controller (`config.parent_controller`) that
# is absent from the gem's own unit suite, so it cannot be a Zeitwerk-managed
# file (eager-loading it would raise). It is built on demand by
# `McpToolkit.build_engine_controllers!`, so this `const_missing` triggers that
# build the first time `McpToolkit::Authority::ServerController` is referenced
# (which, in a host, is after the app's initializers/to_prepare have run — so the
# configured parent is read at build time, not at autoload time).
module McpToolkit::Authority
  def self.const_missing(name)
    if name == :ServerController
      McpToolkit.build_engine_controllers!
      return const_get(name) if const_defined?(name, false)
    end

    super
  end
end
