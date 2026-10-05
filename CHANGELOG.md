# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). Before 1.0 the database schema may change between minor versions:
regenerate the migration when upgrading.

## [Unreleased]

## [0.2.0] - 2026-10-05

Second version: see it and operate it.

### Added

- `ActiveDurable.retry`, `ActiveDurable.compensate` and `ActiveDurable.rerun` (see `ActiveDurable::Operations`).
  They refuse executions a worker holds and rotate the lease token.
- Reruns: a new execution (`<id>~rerun-N`, `forked_from`) that reuses the completed steps before a chosen step.
  A blocked original becomes `superseded`.
- The dashboard engine (`mount ActiveDurable::Engine => "/durable"`): executions by status and recipe, notebooks
  with tickets, undos and signals, and the three operations. It works in API-only apps with its own cookie
  session and CSRF protection, and is closed in production until `config.dashboard_authorize` is set.
- Events: `completed`, `compensated`, `blocked`, `retried`, `compensation_requested` and `rerun`
  (`*.active_durable`).
- `bin/demo` to browse the dashboard with sample sagas.

### Changed

- Requires Ruby 3.3+ (3.2 is end of life) and Rails 7.2+.
- A compensation that reaches a completed `flow.pivot` blocks instead of undoing past the point of no return.
- Schema: `durable_executions.forked_from` (regenerate the migration).

## [0.1.0] - 2026-10-05

First version: nothing gets lost.

### Added

- `Durable.define` and `Durable.start`: named recipes and executions stored in `durable_executions`. The execution
  row is the outbox: the job is enqueued after commit.
- The notebook (`durable_steps`): steps are checkpointed and skipped on replay.
- `flow.step` with a stable ticket per step for idempotency keys, and retries with configurable backoff.
- `flow.transaction`: a database-only step committed together with its checkpoint (exactly once).
- `flow.pivot`: the point of no return. Before it failures compensate; after it steps are retried, then blocked.
- Compensation in reverse order, checkpointed per undo and resumable after a crash. `undo_on_failure:` for steps
  whose failure may hide a success.
- `flow.sleep`, `flow.wait_for` and `Durable.signal` (`durable_signals`), without holding a worker.
- A lease with a fencing token: one worker per execution, and a worker that lost its lease cannot write.
- The recipe-changed alarm (`ActiveDurable::RecipeChanged`) and checks for duplicated step names and non-JSON
  results.
- `ActiveDurable::Sweeper` / `SweepJob` / `rake active_durable:sweep` for lost jobs and expired leases.
- `ActiveDurable::Testing.crash_everywhere` and `ActiveDurable::Testing.drain`.
- `rails generate active_durable:install`.
- `ActiveSupport::Notifications` events: `execution.active_durable`, `step.active_durable`,
  `compensation.active_durable` and `undo.active_durable`.
