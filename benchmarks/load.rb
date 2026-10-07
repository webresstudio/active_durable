# frozen_string_literal: true

# Many worker processes on the same sagas, as a job backend with several workers would run them. With CHAOS=1 a
# random worker is killed with SIGKILL every second and replaced: the lease runs out, another worker takes over,
# and the charges must still happen once per saga.
#
#   DB=postgresql bundle exec ruby benchmarks/load.rb
#   DB=postgresql CHAOS=1 bundle exec ruby benchmarks/load.rb
require_relative "support"

SAGAS = Integer(ENV.fetch("SAGAS", 2_000))
WORKERS = Integer(ENV.fetch("WORKERS", 8))
CHAOS = ENV["CHAOS"] == "1"
IO_MS = Float(ENV.fetch("IO_MS", 5)) # the time a call to the outside world takes

ActiveDurable.config.lease_duration = 3 if CHAOS # a dead worker's lease runs out quickly
ActiveDurable.config.parallel_concurrency = 1

Durable.define(:checkout) do |flow|
  flow.transaction(:reserve) { { "reserved" => true } }
  flow.step(:charge) do |ticket|
    sleep(IO_MS / 1000.0)
    BenchCharge.charge!(ticket)
    { "id" => ticket }
  end
  flow.step(:ship) { sleep(IO_MS / 1000.0) && true }
  flow.transaction(:mark_shipped) { true }
  flow.step(:email) { sleep(IO_MS / 1000.0) && true }
end

# What a job backend would hand a worker: executions nobody holds, in random order to make workers collide.
def work
  ActiveRecord::Base.establish_connection(TestDatabase.config)
  loop do
    now = ActiveDurable.now
    ids = ActiveDurable::Execution.active.where("locked_until IS NULL OR locked_until < ?", now)
                                  .limit(50).pluck(:id).shuffle
    break if ids.empty? && ActiveDurable::Execution.active.none?

    ids.each { |id| ActiveDurable::Runner.run(id) }
    sleep 0.05 if ids.empty?
  end
end

puts "ActiveDurable #{ActiveDurable::VERSION} · #{Bench.database} · #{Bench.machine}"
puts "#{SAGAS} sagas of 5 steps (#{IO_MS} ms per outside call), #{WORKERS} worker processes" \
     "#{", SIGKILL every second" if CHAOS}"

Bench.clean!
SAGAS.times { ActiveDurable::Testing.start_quietly(:checkout, {}) }
ActiveRecord::Base.connection_handler.clear_all_connections!

kills = 0
seconds = Bench.realtime do
  pids = Array.new(WORKERS) { fork { work } }
  if CHAOS
    until pids.all? { |pid| Process.waitpid(pid, Process::WNOHANG) }
      sleep 1
      victim = pids.sample
      begin
        Process.kill(:KILL, victim)
        Process.waitpid(victim)
        kills += 1
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      pids[pids.index(victim)] = fork { work }
      ActiveRecord::Base.establish_connection(TestDatabase.config)
      break if ActiveDurable::Execution.active.none?
    end
    pids.each { |pid| Process.waitpid(pid) rescue Errno::ECHILD } # rubocop:disable Style/RescueModifier
  else
    pids.each { |pid| Process.waitpid(pid) }
  end
end
ActiveRecord::Base.establish_connection(TestDatabase.config)

completed = ActiveDurable::Execution.where(status: "completed").count
charges = BenchCharge.count
attempts = BenchCharge.sum(:attempts)
puts
puts format("%<sagas>d/%<total>d completed in %<s>.1f s: %<rate>.0f sagas/s, %<steps>.0f steps/s",
            sagas: completed, total: SAGAS, s: seconds, rate: completed / seconds, steps: completed * 5 / seconds)
puts "workers killed with SIGKILL: #{kills}" if CHAOS
puts "charges: #{charges} for #{SAGAS} sagas (calls to the provider: #{attempts}, " \
     "#{attempts - charges} repeated with the same ticket)"
abort "FAILED: a saga did not complete or a charge was duplicated" unless completed == SAGAS && charges == SAGAS
