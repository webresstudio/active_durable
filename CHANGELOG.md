# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/). Before 1.0 the database schema may change between minor versions:
regenerate the migration when upgrading.

## [Unreleased]

### Changed

- Supports Ruby 3.1+ and Rails 6.1+ (was Ruby 3.3+ and Rails 7.2+), with every feature on every version. The
  notebook no longer relies on `ActiveRecord.after_all_transactions_commit`: `flow.transaction` steps and their
  undos run inside `Notebook#transaction`, which remembers their writes only once the transaction commits.
- CI covers Ruby 3.1, 3.2, 3.3, 3.4 and 4.0 against Rails 6.1, 7.0, 7.1, 7.2, 8.0 and 8.1 and the three
  databases (84 jobs). MySQL runs on mysql2 for Rails 6.1 and 7.0, and on trilogy from 7.1. Each job resolves its own gems from `gemfiles/rails-X.Y.gemfile`; per-Rails lockfiles are no longer
  committed, so they can never fall behind the gem version (which broke the 0.4.0 CI run).

- The README is rewritten, with animated explanations (`docs/assets/*.svg`, built by `docs/assets/generate.rb`),
  dashboard screenshots, a state diagram and a compatibility table.
- The README also exists in Spanish (`README.es.md`, with its own animations). `CONTRIBUTING.md` and `CLAUDE.md`
  ask to update both, and `spec/readme_spec.rb` fails when they drift apart.
- Dashboard: long step names wrap at underscores, and notebook results get room to breathe.

### Fixed

- Dashboard: on Rails 6.1 and 7.0, `Rails.env.local?` silently answered false, which would have closed the
  dashboard in development too. It now checks for development and test explicitly.
- Migration: datetime columns are created with microsecond precision on every Rails version.
- The packaged gem no longer includes `gemfiles/`.

## [0.4.0] - 2026-10-05

The dashboard, redrawn.

### Changed

- The dashboard is redrawn full screen: a rail with statuses and recipes, and every saga shown as a row of blocks.
  Each block's animation tells its state (running beats, a waiting step pings like a radar, a sleeping one fills
  a ring until it wakes, a failed one shakes, undone ones are striped and wired backwards), with a visible point
  of no return, live countdowns, and a live mode that refreshes the list and flashes the rows that changed.
  Animations stop when the system asks for reduced motion.
- The gemspec links to the GitHub repository (homepage, source, changelog and issues).

## [0.3.0] - 2026-10-05

Third version: everything the design called "later", except the Rust gem.

### Added

- `flow.parallel`: branches that run in threads, each checkpointed with its own ticket and retries. Unfinished
  branches resume after a crash; completed ones are undone in the order they finished. Branch threads run inside
  the Rails executor and keep OpenTelemetry context.
- Recipe versions: `Durable.define(name, version:)`, executions keep the version they started with,
  `ActiveDurable.versions_in_use` and `rake active_durable:versions`.
- `ActiveDurable::OpenTelemetry.install!`: nested spans for executions, steps, compensations and undos.
- `ActiveDurable.branch_wrappers` to carry other thread-local context into parallel branches.

### Fixed

- The dashboard was open in every environment except production (staging included). Without
  `config.dashboard_authorize` it now opens only in development and test.

### Changed

- MySQL 8+ and SQLite 3 are supported and run the full suite, like PostgreSQL. Tested on Rails 7.2, 8.0 and 8.1.
- The notebook is safe to write from several threads, and only remembers writes whose transaction committed.
- The registry looks the recipe constant up on every use, so an edited recipe is picked up after a code reload
  in development.
- One Gemfile per Rails version (`gemfiles/`) with lockfiles for Linux, used by the CI matrix.

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
