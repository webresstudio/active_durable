# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_durable.gemspec
gemspec

rails_version = ENV.fetch("RAILS_VERSION", "~> 8.1.0")

gem "actionpack", rails_version
gem "actionview", rails_version
gem "activejob", rails_version
gem "activerecord", rails_version
gem "activesupport", rails_version
gem "railties", rails_version
# Active Support 8.0 still passes quirks_mode to JSON.generate, which json 3 removed.
gem "json", "< 3" if rails_version.include?("8.0")

gem "pg", "~> 1.5"
gem "sqlite3", ">= 2.1"
gem "trilogy", "~> 2.9"

gem "opentelemetry-sdk", "~> 1.5"
gem "puma", "~> 7.0" # bin/demo
gem "rack-test", "~> 2.1"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"
