# frozen_string_literal: true

require_relative "lib/active_durable/version"

Gem::Specification.new do |spec|
  spec.name = "active_durable"
  spec.version = ActiveDurable::VERSION
  spec.authors = ["William Romero"]
  spec.email = ["williamromerovela@gmail.com"]

  spec.summary = "Durable sagas for Rails: finish the work or undo it in order, even if the server dies."
  spec.description = <<~DESC
    ActiveDurable runs multi-step business flows (checkouts, onboarding, payouts) as durable sagas
    stored in your own database. Completed steps are checkpointed and never repeated after a crash,
    failures before the point of no return are compensated in reverse order, and failures after it
    are retried. No Redis and no extra servers: just Active Record and Active Job.
  DESC
  spec.license = "MIT"
  spec.homepage = "https://github.com/williamromero/active_durable"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Only ship what the gem needs at runtime: the design notes in docs/ stay in the repo.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ docs/ gemfiles/ .git .github appveyor Gemfile .rubocop .rspec])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activejob", ">= 7.2"
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "activesupport", ">= 7.2"
end
