# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in mcp_toolkit.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

# Used by the auth specs to stub the central app's introspection endpoint.
gem "webmock", "~> 3.0"

# Rails is NOT a gem runtime dependency (the gem depends on activesupport only, so
# non-Rails hosts can consume it). It is pulled in here, for the test suite alone,
# so the engine regression spec can boot a REAL minimal Rails::Application and
# drive its routes_reloader — the only thing that reproduces the route-reload wipe
# the engine's config/routes.rb fixes. `require: false` keeps it out of the gem's
# own load path.
gem "rails", "~> 8.0", require: false

# Linting, static analysis, and security scanning. `require: false` so they load
# only via their CLIs / Rake tasks, never into the gem's runtime.
gem "brakeman", require: false
gem "rubocop", require: false
gem "rubocop-performance", require: false
