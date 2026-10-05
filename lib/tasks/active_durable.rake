# frozen_string_literal: true

namespace :active_durable do
  desc "Enqueue executions that should be running but have no job (run it every minute)"
  task sweep: :environment do
    ids = ActiveDurable::Sweeper.call
    puts "ActiveDurable: enqueued #{ids.size} execution(s)"
  end
end
