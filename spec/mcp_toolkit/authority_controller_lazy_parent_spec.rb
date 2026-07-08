# frozen_string_literal: true

require "spec_helper"

# Constraint B regression spec: the gem-provided controllers subclass
# `config.parent_controller`, and that parent MUST be read at BUILD time — after
# the host's initializer/to_prepare has run — not at autoload/eager-load time. If
# it were read early it would default to ActionController::Base, breaking CSRF
# handling on the introspection endpoint.
#
# Only a REAL booted Rails::Application driving its initializers + prepare
# callbacks reproduces the timing; a stub cannot. Booting one in-process mutates
# irreversible global state (Rails.application, the Zeitwerk loader set the
# eager_load_spec inspects, the const-set controllers), so — like
# engine_route_reload_spec — the boot runs in an ISOLATED CHILD process that sets
# the parent ENTIRELY inside `config.to_prepare` (the worst case), references the
# lazily-built controllers, and prints their superclasses as JSON for this parent
# process to assert on.
rails_available =
  begin
    require "rails/version"
    true
  rescue LoadError
    false
  end

RSpec.describe "Authority controllers resolve their parent lazily (Constraint B)", if: rails_available do
  LAZY_PARENT_CONTROLLER_DRIVER = <<~'RUBY'
    require "bundler/setup"
    require "json"
    require "tmpdir"
    require "logger"
    require "mcp_toolkit"
    require "rails"
    require "action_controller/railtie"

    # mcp_toolkit is required before Rails here, so load the (Zeitwerk-ignored)
    # engine explicitly by path.
    unless McpToolkit.const_defined?(:Engine, false)
      load File.expand_path("lib/mcp_toolkit/engine.rb", Dir.pwd)
    end

    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.consider_all_requests_local = true
      config.secret_key_base = "lazy-parent-spec-secret-key-base"
      config.logger = Logger.new(IO::NULL)
      config.root = Dir.mktmpdir("mcp_toolkit_lazy_parent_spec")

      # The whole MCP config lives in to_prepare (the to_prepare-safe pattern):
      # the parent is set AFTER the engine's own to_prepare in the same cycle, so a
      # correct result proves the parent is read at build (reference) time, not at
      # autoload time.
      config.to_prepare { McpToolkit.config.parent_controller = "ActionController::API" }
    end

    app.initialize!
    app.routes.draw { mount McpToolkit::Engine => "/mcp" }

    # Referencing each controller AFTER boot triggers the lazy build (const_missing).
    puts JSON.generate(
      "server_parent"          => McpToolkit::ServerController.superclass.name,
      "tokens_parent"          => McpToolkit::TokensController.superclass.name,
      "authority_parent"       => McpToolkit::Authority::ServerController.superclass.name,
      "tokens_has_introspect"  => McpToolkit::TokensController.instance_methods.include?(:introspect),
      "authority_has_create"   => McpToolkit::Authority::ServerController.instance_methods.include?(:create)
    )
  RUBY

  before(:all) do
    require "json"
    require "open3"

    gem_root = File.expand_path("../..", __dir__)
    stdout, stderr, status = Open3.capture3(Gem.ruby, "-e", LAZY_PARENT_CONTROLLER_DRIVER, chdir: gem_root)
    raise "lazy-parent driver failed (#{status.exitstatus}):\n#{stderr}" unless status.success?

    @result = JSON.parse(stdout.lines.last)
  end

  it "builds the engine ServerController against the configured parent" do
    expect(@result.fetch("server_parent")).to eq("ActionController::API")
  end

  it "builds the engine TokensController against the configured parent, preserving #introspect" do
    expect(@result.fetch("tokens_parent")).to eq("ActionController::API")
    expect(@result.fetch("tokens_has_introspect")).to be(true)
  end

  it "builds the Authority::ServerController base against the configured parent, with the transport wired" do
    expect(@result.fetch("authority_parent")).to eq("ActionController::API")
    expect(@result.fetch("authority_has_create")).to be(true)
  end
end
