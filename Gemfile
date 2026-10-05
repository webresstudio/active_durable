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

gem "pg", "~> 1.5"
gem "sqlite3", ">= 2.1"
gem "trilogy", "~> 2.9"

gem "puma", "~> 7.0" # bin/demo
gem "rack-test", "~> 2.1"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"
