# frozen_string_literal: true

# CI installs each gemfile in frozen mode: a lockfile that still records an old version of this gem fails there.
RSpec.describe "gemfiles/*.gemfile.lock" do
  Dir[File.expand_path("../gemfiles/*.gemfile.lock", __dir__)].each do |lockfile|
    it "#{File.basename(lockfile)} records version #{ActiveDurable::VERSION} (run rake gemfiles:lock)" do
      expect(File.read(lockfile)).to include("    active_durable (#{ActiveDurable::VERSION})")
    end
  end
end
