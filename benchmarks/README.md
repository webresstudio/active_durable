# Benchmarks

Two scripts, run against the same databases as the test suite (`DB=postgresql`, `mysql` or `sqlite3`; see
[CONTRIBUTING.md](../CONTRIBUTING.md)). They drop and recreate the test tables.

## What a step costs: `throughput.rb`

```bash
DB=postgresql bundle exec ruby benchmarks/throughput.rb
```

Runs 200 sagas of 10 steps back to back in one process (`SAGAS=` to change it), once with `flow.step` and once with
`flow.transaction`, and prints the time and queries per step. Then it resumes a saga that already has 100 and 1,000
finished steps, which is what a worker does after a crash: it replays the recipe against the notebook and runs only
the new step.

## Many workers, and workers that die: `load.rb`

```bash
DB=postgresql bundle exec ruby benchmarks/load.rb
DB=postgresql CHAOS=1 bundle exec ruby benchmarks/load.rb
```

Starts 2,000 sagas of 5 steps (`SAGAS=`) and forks 8 worker processes (`WORKERS=`) that pick executions nobody holds,
in random order, so they collide on purpose and the lease has to sort them out. Each call to the outside world sleeps
5 ms (`IO_MS=`); the charge step writes to a table that behaves like a payment provider: the same ticket is the same
charge, and every call is counted.

With `CHAOS=1` the lease lasts 3 seconds and a random worker is killed with SIGKILL every second and replaced. The
script fails unless every saga completes and there is exactly one charge per saga.

## Results

Apple M1 Ultra, Ruby 4.0.7, Rails 8.1.4, PostgreSQL 16.13, MySQL 9.6.0 (trilogy), SQLite 3.53, on the same machine.

| | PostgreSQL | MySQL | SQLite |
| --- | --- | --- | --- |
| `flow.step` | 1.82 ms, 4.4 queries | 2.98 ms, 4.4 queries | 0.45 ms, 4.4 queries |
| `flow.transaction` | 1.99 ms | 2.81 ms | 0.45 ms |
| Resume with 100 / 1,000 finished steps | 6.8 / 17.3 ms | 5.6 / 20.8 ms | 2.7 / 9.1 ms |
| 2,000 sagas, 8 workers | 6.9 s, 290 sagas/s | 8.1 s, 246 sagas/s | 1,000 sagas, 4 workers: 6.5 s |
| With `CHAOS=1` | 9.2 s, 9 workers killed | 13.2 s, 13 killed | — |
| Charges for 2,000 sagas | 2,000 (2 calls repeated with the same ticket) | 2,000 | 1,000 for 1,000 |

## In a real app

The same check, done by hand in a fresh Rails 8.1 app with PostgreSQL and Solid Queue (2 worker processes of 3
threads, the sweeper scheduled every minute, a 20-second lease): 300 checkouts (240 that succeed, 30 declined cards,
30 refused parcels) and every Solid Queue process killed with SIGKILL twice, with 6 and then 11 sagas halfway through.
All 301 sagas settled in 77 seconds: 241 shipped with one charge each, 30 cancelled without a charge, 30 cancelled
with their charge refunded once, and no order charged twice.
