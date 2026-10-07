# frozen_string_literal: true

# What a step costs: queries and time per step in one process, against the database in DB.
#
#   DB=postgresql bundle exec ruby benchmarks/throughput.rb
require_relative "support"

SAGAS = Integer(ENV.fetch("SAGAS", 200))
STEPS = 10

Durable.define(:steps) do |flow|
  STEPS.times { |i| flow.step(:"s#{i}") { i } }
end
Durable.define(:transactions) do |flow|
  STEPS.times { |i| flow.transaction(:"t#{i}") { i } }
end
Durable.define(:long) do |flow, steps:|
  steps.times { |i| flow.step(:"s#{i}") { i } }
end

def run_sagas(recipe)
  ids = Array.new(SAGAS) { ActiveDurable::Testing.start_quietly(recipe, {}) }
  queries = 0
  seconds = Bench.realtime do
    queries = Bench.count_queries { ids.each { |id| ActiveDurable::Runner.run(id) } }
  end
  raise "not every saga completed" unless ActiveDurable::Execution.where(status: "completed").count == SAGAS

  [seconds, queries]
end

puts "ActiveDurable #{ActiveDurable::VERSION} · #{Bench.database} · #{Bench.machine}"
puts "#{SAGAS} sagas of #{STEPS} steps, one process, run back to back"
puts
puts "| | per step | queries per step | sagas per second |"
puts "| --- | --- | --- | --- |"
%i[steps transactions].each do |recipe|
  Bench.clean!
  run_sagas(recipe) # warm up
  Bench.clean!
  seconds, queries = run_sagas(recipe)
  per_step = seconds * 1000 / (SAGAS * STEPS)
  per_step_queries = queries.to_f / (SAGAS * STEPS)
  name = recipe.to_s.delete_suffix("s")
  puts format("| flow.%-11<name>s | %<ms>.2f ms | %<q>.1f | %<rate>.0f |",
              name: name, ms: per_step, q: per_step_queries, rate: SAGAS / seconds)
end

# Resuming after a crash replays the recipe against the notebook: finished steps are read, not run.
Bench.clean!
[100, 1000].each do |done|
  id = ActiveDurable::Testing.start_quietly(:long, { steps: done })
  ActiveDurable::Runner.run(id) # writes `done` entries
  ActiveDurable::Execution.where(id: id).update_all(status: "pending")
  Durable.define(:long, version: 2) { |flow, steps:| (steps + 1).times { |i| flow.step(:"s#{i}") { i } } }
  ActiveDurable::Execution.where(id: id).update_all(recipe_version: 2)
  seconds = Bench.realtime { ActiveDurable::Runner.run(id) }
  puts
  puts format("Resuming a saga with %<done>d finished steps (replay + 1 new step): %<ms>.1f ms",
              done: done, ms: seconds * 1000)
end
