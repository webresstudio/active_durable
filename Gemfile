# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_durable.gemspec
gemspec

# Rails 8.1 for development. CI runs every gemfiles/rails-*.gemfile
# (BUNDLE_GEMFILE=gemfiles/rails-7.1.gemfile bundle exec rspec).
%w[actionpack actionview activejob activerecord activesupport railties].each { |name| gem name, "~> 8.1.0" }
gem "sqlite3", ">= 2.1"
gem "trilogy", "~> 2.9" # MySQL

eval_gemfile "gemfiles/shared.gemfile"
