# frozen_string_literal: true

namespace :active_durable do
  desc "List recipe versions that unfinished executions still use, so you know when an old version can go"
  task versions: :environment do
    in_use = ActiveDurable.versions_in_use
    if in_use.empty?
      puts "No unfinished executions."
    else
      in_use.sort.each do |(recipe, version), count|
        defined = ActiveDurable.registry.versions_for(recipe).any? { |r| r.version == version }
        puts format("%-30<recipe>s v%-4<version>d %6<count>d unfinished%<warning>s",
                    recipe: recipe, version: version, count: count,
                    warning: defined ? "" : "  <- NOT DEFINED: these executions will block")
      end
    end
  end

  desc "Delete finished executions older than config.keep_finished_for, with their notebook (run it daily)"
  task prune: :environment do
    days = (ActiveDurable.config.keep_finished_for.to_f / 86_400).round(2)
    days = days.to_i if days == days.to_i
    puts "ActiveDurable: deleted #{ActiveDurable.prune} finished execution(s) older than #{days} days"
  end

  desc "Enqueue executions that should be running but have no job (run it every minute)"
  task sweep: :environment do
    ids, how = ActiveDurable::Sweeper.call_from_task
    if how == :ran
      puts "ActiveDurable: ran #{ids.size} execution(s) in this process (the :async adapter would lose their jobs)"
    else
      puts "ActiveDurable: enqueued #{ids.size} execution(s)"
    end
  end
end
