# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

# Run brakeman with the same flags CI uses, so a local `rake` catches what the
# pipeline would.
desc "Run Brakeman security scanner"
task :brakeman do
  sh "bundle exec brakeman --force --no-progress --quiet --no-pager"
end

# Convenience "everything" task for local runs — mirrors CI (which keeps these as
# separate jobs: test / rubocop / brakeman) so a green `rake` means a green build.
task default: %i[spec rubocop brakeman]
