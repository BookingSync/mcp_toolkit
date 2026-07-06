# frozen_string_literal: true

require "spec_helper"

# Regression spec for the route-reloader wipe.
#
# The engine draws its MCP routes in the engine's `config/routes.rb` rather
# than in a class-body `McpToolkit::Engine.routes.draw` block. The reason is
# Rails' routes_reloader: a host application builds its route set lazily and runs
# the reloader on boot (and again on every reload). The reloader re-evaluates each
# mounted engine's `config/routes.rb`, but it never replays a `routes.draw` that
# ran once at class-body load time — under a lazily-loaded app that class-body
# draw is dropped, leaving the engine with ZERO routes and every `/mcp` request
# 404'ing. Moving the draw into config/routes.rb is what makes the routes
# materialize and survive subsequent reloads.
#
# The sibling engine_spec.rb stubs Rails and asserts the routes are *drawn*,
# but a stub cannot reproduce the reloader: only a REAL Rails::Application driving
# its routes_reloader does, which is why the original bug slipped through.
#
# Booting a real Rails::Application IN-PROCESS is not viable here: it irreversibly
# mutates global state (Rails.application, the Zeitwerk loader set that the
# eager_load_spec inspects, the engine's lazy route set) and contaminates the rest
# of this Rails-absent suite across random orderings. So the boot runs in an
# ISOLATED CHILD Ruby process: it boots a minimal app, mounts the engine, forces a
# route reload, and prints the engine's route set as JSON before and after the
# reload. This parent process asserts on that JSON, fully insulated from the boot.
#
# Rails-only: railties/actionpack are a TEST dependency (see Gemfile), not a gem
# runtime dependency, so the group is skipped when Rails is unavailable, keeping
# the non-Rails unit suite clean.
rails_available =
  begin
    require "rails/version"
    true
  rescue LoadError
    false
  end

RSpec.describe "Engine survives a route reload", if: rails_available do
  # The endpoints as [verb, engine-relative path, controller#action]. Paths are
  # relative to the engine's own route set (the `/mcp` mount supplies the prefix),
  # so the roots are "/" and the probe is "/health". `mcp_toolkit/server` /
  # `mcp_toolkit/tokens` are the isolated-namespace paths of the gem-provided
  # McpToolkit::ServerController / McpToolkit::TokensController.
  EXPECTED_ENGINE_ROUTES = [
    ["POST",   "/",                  "mcp_toolkit/server#create"],
    ["GET",    "/",                  "mcp_toolkit/server#stream"],
    ["DELETE", "/",                  "mcp_toolkit/server#destroy"],
    ["GET",    "/health",            "mcp_toolkit/server#health"],
    ["POST",   "/tokens/introspect", "mcp_toolkit/tokens#introspect"]
  ].freeze

  # The driver script: boots a real, minimal Rails app in a child process, mounts
  # the engine, captures the engine route set, forces a route reload, captures it
  # again, and prints both as a single JSON line for the parent to assert on. Any
  # failure inside the boot surfaces as a non-zero exit + captured stderr.
  DRIVER = <<~'RUBY'
    # Load THIS bundle in the child (BUNDLE_GEMFILE is inherited from the parent
    # ENV) so rails + mcp_toolkit resolve to the same locked gems even though the
    # child interpreter is invoked directly via Gem.ruby (not `bundle exec`).
    require "bundler/setup"
    require "json"
    require "tmpdir"
    require "logger"
    require "mcp_toolkit"
    require "rails"
    require "action_controller/railtie"

    # Default parent_controller; ActionController::Base (not ::API) keeps the
    # gem-provided controller (which includes the transport concern) loadable.
    McpToolkit.config.parent_controller = "ActionController::Base"

    # The gem requires engine.rb only when Rails::Engine is already defined at the
    # moment mcp_toolkit loads; here mcp_toolkit is required before Rails, so load
    # the (Zeitwerk-ignored) engine explicitly by path.
    unless McpToolkit.const_defined?(:Engine, false)
      load File.expand_path("lib/mcp_toolkit/engine.rb", Dir.pwd)
    end

    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.consider_all_requests_local = true
      config.secret_key_base = "regression-spec-secret-key-base"
      config.logger = Logger.new(IO::NULL)
      config.root = Dir.mktmpdir("mcp_toolkit_engine_spec")
    end

    app.initialize!
    app.routes.draw { mount McpToolkit::Engine => "/mcp" }

    extract = lambda do
      McpToolkit::Engine.routes.routes.map do |route|
        path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
        [route.verb, path, "#{route.defaults[:controller]}##{route.defaults[:action]}"]
      end
    end

    # Capture the mount BEFORE reloading: the parent app's mount was drawn
    # imperatively (app.routes.draw { ... }), not from a routes file, so the
    # reload wipes the PARENT's route set too — the engine routes survive only
    # because they live in the engine's file-based config/routes.rb. That asymmetry
    # is the whole point, so the mount assertion is taken pre-reload.
    mount = app.routes.routes.find { |r| r.app.app == McpToolkit::Engine }
    mount_path = mount && mount.path.spec.to_s

    before_reload = extract.call
    app.reload_routes!  # the exact trigger that wiped a class-body draw
    after_reload  = extract.call

    puts JSON.generate(
      "mount_path"    => mount_path,
      "before_reload" => before_reload,
      "after_reload"  => after_reload
    )
  RUBY

  # Boot once for the group; the child process is the expensive part.
  before(:all) do
    require "json"
    require "open3"

    gem_root = File.expand_path("../..", __dir__)
    # Invoke the RUNNING interpreter directly via Gem.ruby (full path). A bare
    # "bundle","exec","ruby" can resolve a SYSTEM ruby under a Bundler-managed
    # parent; Gem.ruby is the portable way to re-enter the same interpreter. The
    # child still loads the same locked gems because the driver does
    # `require "bundler/setup"` and inherits BUNDLE_GEMFILE from this ENV.
    stdout, stderr, status = Open3.capture3(
      Gem.ruby, "-e", DRIVER, chdir: gem_root
    )
    raise "engine route-reload driver failed (#{status.exitstatus}):\n#{stderr}" unless status.success?

    @result = JSON.parse(stdout.lines.last)
  end

  it "mounts the engine in the host app under /mcp" do
    expect(@result.fetch("mount_path")).to eq("/mcp")
  end

  it "draws the MCP endpoints in the engine route set once booted" do
    # JSON parses each route back to a [verb, path, action] array, matching the
    # shape of EXPECTED_ENGINE_ROUTES.
    expect(@result.fetch("before_reload")).to contain_exactly(*EXPECTED_ENGINE_ROUTES)
  end

  it "still holds them after the app reloads its routes (the regression)" do
    after_reload = @result.fetch("after_reload")

    # NON-EMPTY (the old class-body form left it empty after the reload)...
    expect(after_reload).not_to be_empty
    # ...and still mapping every endpoint to the right controller action.
    expect(after_reload).to contain_exactly(*EXPECTED_ENGINE_ROUTES)
  end
end
