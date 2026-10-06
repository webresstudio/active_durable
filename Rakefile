# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

task default: %i[spec rubocop]

namespace :gemfiles do
  desc "Relock gemfiles/rails_*.gemfile (run it after changing the version or the gemspec)"
  task :lock do
    Dir["gemfiles/rails_*.gemfile"].each do |gemfile|
      # A clean environment: under bundle exec the child would inherit the main Gemfile's settings.
      Bundler.with_unbundled_env { sh({ "BUNDLE_GEMFILE" => File.expand_path(gemfile) }, "bundle lock") }
    end
  end
end
