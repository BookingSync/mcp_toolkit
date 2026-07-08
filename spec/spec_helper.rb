# frozen_string_literal: true

require "mcp_toolkit"
require "webmock/rspec"
# stdlib Logger, so gateway specs can `instance_double(Logger, ...)` a config.logger.
require "logger"

# Block all real HTTP; auth specs stub the central app's introspection endpoint.
WebMock.disable_net_connect!

Dir[File.join(__dir__, "support", "**", "*.rb")].each { |f| require f }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Each example starts from a pristine, default configuration.
  config.before do
    McpToolkit.reset_config!
  end
end
