# frozen_string_literal: true

require_relative "lib/mcp_toolkit/version"

Gem::Specification.new do |spec|
  spec.name = "mcp_toolkit"
  spec.version = McpToolkit::VERSION
  spec.authors = ["Karol Galanciak"]
  spec.email = ["karol.galanciak@gmail.com"]

  spec.summary = "Opinionated toolkit for building account-scoped, read-only MCP servers."
  spec.description = <<~DESC
    mcp_toolkit extracts the shared MCP-server framework that Smily's apps grew
    independently: a Streamable-HTTP transport, cache-backed sessions, central-app
    token introspection (satellite + authority roles), a registry-driven
    "generic tools over N resources" dispatcher, and an injectable serializer DSL.
    It wraps the official `mcp` gem as the JSON-RPC core so each app ships only its
    serializers, resource registrations, and scope blocks.
  DESC
  spec.homepage = "https://github.com/BookingSync/mcp_toolkit"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .circleci/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Zeitwerk autoloads the gem's lib tree, so there are no manual require
  # statements for the gem's own files.
  spec.add_dependency "zeitwerk", "~> 2.6"
  # The official MCP SDK is the JSON-RPC dispatcher core this toolkit wraps.
  spec.add_dependency "mcp", "~> 0.18"
  # activesupport supplies the cache-store contract, time, and Hash/Array helpers
  # the toolkit relies on (deep_symbolize_keys, Array.wrap, iso8601, ...). We
  # depend on it, not on full Rails, so non-Rails hosts can consume the gem.
  spec.add_dependency "activesupport", ">= 6.1"
  # faraday is the HTTP client the satellite uses to introspect tokens against
  # the central app.
  spec.add_dependency "faraday", ">= 1.0"
end
