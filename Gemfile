# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in active_durable.gemspec
gemspec

# Rails 8.1 for development. Other versions: gemfiles/rails_7_2.gemfile and gemfiles/rails_8_0.gemfile
# (BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle exec rspec).
%w[actionpack actionview activejob activerecord activesupport railties].each { |name| gem name, "~> 8.1.0" }

eval_gemfile "gemfiles/shared.gemfile"
