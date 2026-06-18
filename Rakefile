# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

# Convenience "everything" task for local runs. CI (GitHub Actions) keeps these
# as separate jobs (test / rubocop / brakeman) so failures stay isolated.
task default: %i[spec rubocop]
