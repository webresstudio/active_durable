# ActiveDurable

Durable sagas for Rails. When a multi-step flow fails halfway, ActiveDurable finishes the work or undoes it in
order, even if the server dies in the middle.

- **Stored in your database.** No Redis, no workflow server. Active Record and Active Job only.
- **Steps are checkpointed.** A crashed saga resumes on another worker and skips what already happened.
- **Undo in reverse order.** Steps declare how to undo themselves; failures before the point of no return are
  compensated last-to-first.
- **A point of no return.** After `flow.pivot`, failures are retried instead of undone.
- **Exactly-once database steps.** `flow.transaction` commits your change and its checkpoint together.
- **A crash tester.** `ActiveDurable::Testing.crash_everywhere` kills your saga at every possible point and lets
  you assert nothing was duplicated.

Rails 7.2+, Ruby 3.2+, PostgreSQL (MySQL and SQLite: see the changelog).

## Installation

```bash
bundle add active_durable
bin/rails generate active_durable:install
bin/rails db:migrate
```

Schedule the sweeper every minute. With Solid Queue, in `config/recurring.yml`:

```yaml
production:
  active_durable_sweep:
    class: ActiveDurable::SweepJob
    schedule: every minute
```

## A checkout in five steps

```ruby
# app/sagas/checkout_saga.rb
CheckoutSaga = Durable.define(:checkout) do |flow, order_id:|
  order = Order.find(order_id) # reads are fine outside steps: they repeat on every replay

  # Touches only your database: runs in the same transaction as its checkpoint, so exactly once.
  flow.transaction(:reserve_stock, undo: ->(_) { order.release_stock! }) do
    order.reserve_stock!
    { "reserved" => true }
  end

  # Talks to the outside world: pass the ticket as the idempotency key.
  payment = flow.step(:charge,
                      undo: lambda { |charge, ticket|
                        Stripe::Refund.create({ payment_intent: charge["id"] }, { idempotency_key: ticket })
                      }) do |ticket|
    intent = Stripe::PaymentIntent.create(
      { amount: order.total_cents, currency: "usd", customer: order.user.stripe_id, confirm: true },
      { idempotency_key: ticket }
    )
    { "id" => intent.id }
  end

  # The point of no return: before it, failures are undone; after it, steps are retried.
  flow.pivot(:dispatch) do |ticket|
    shipment = Carrier.ship(order.id, reference: ticket)
    { "tracking" => shipment.tracking_number, "payment" => payment["id"] }
  end

  flow.step(:confirmation_email) do
    OrderMailer.shipped(order.id).deliver_now
    true
  end

  flow.sleep(:wait_for_delivery, 3.days) # no worker is held while it sleeps

  flow.step(:ask_for_review) { ReviewMailer.ask(order.id).deliver_now && true }
end
```

Start it inside the transaction that creates the order. The saga row is committed together with the order, and
the job is enqueued only after the commit:

```ruby
Order.transaction do
  order = Order.create!(order_params)
  Durable.start(:checkout, order_id: order.id)
end
```

`Durable` is a short alias for `ActiveDurable`; it is not defined if your app already has a `Durable` constant.

## How it works

Every execution has a **notebook**: one row per step with its status and its result. A worker claims an execution
with a lease and runs the recipe from the top. For each step it checks the notebook. A step that already completed
is not run again: the recorded result is returned. The first step without a result is where the work continues.

That has three consequences you should keep in mind:

1. **Everything that changes the world goes inside a step.** Code outside steps runs again on every replay. Reading
   is fine; writing, charging or sending is not.
2. **Step results are JSON.** They are read back from the notebook, so hashes come back with string keys. To keep
   the first run and a replay identical, the first run also returns the JSON version: `payment["id"]`, never
   `payment[:id]`. Returning something that is not plain JSON blocks the saga with a clear error.
3. **Step names are keys.** Each step needs a unique name within the recipe.

### Steps

| Call | Use it for | On failure |
| --- | --- | --- |
| `flow.step(name, undo:, retry:, undo_on_failure:) { \|ticket\| ... }` | Anything that talks to the outside world | Retried, then the saga compensates |
| `flow.transaction(name, undo:, retry:) { ... }` | Changes to your own database only | Rolled back with its checkpoint, retried, then compensation |
| `flow.pivot(name, retry:) { \|ticket\| ... }` | The step after which there is no going back | Retried, then the saga compensates |
| `flow.sleep(name, duration)` | Waiting without holding a worker | — |
| `flow.wait_for(name, timeout:)` | Waiting for `Durable.signal` | A timeout fails the saga |

### Tickets

Each step receives a **ticket**, `"<execution id>:<step name>"`, which is the same every time the step runs. If a
worker dies after calling Stripe but before writing the checkpoint, the step runs again: with the ticket as the
idempotency key, Stripe answers with the first result instead of charging twice. Undos get their own ticket
(`...:<step name>:undo`).

### Compensation

When a step runs out of attempts (or raises `ActiveDurable::Abort`, or the recipe raises), the saga undoes every
completed step in reverse order. Each undo is checkpointed, so a crash in the middle of compensating resumes where
it stopped. An undo receives `(result, undo_ticket, step_ticket)` and takes as many arguments as it declares.

A step that failed is not undone, because it did not happen. The exception is a step whose failure may hide a
success, like a charge whose answer timed out: declare `undo_on_failure: true` and its undo runs with `nil` as the
result, so it can look the outcome up with the step's ticket.

Rescue `ActiveDurable::StepFailed` inside the recipe to take another path instead:

```ruby
begin
  flow.step(:charge_with_stripe, retry: 2) { |ticket| ... }
rescue ActiveDurable::StepFailed
  flow.step(:charge_with_paypal) { |ticket| ... }
end
```

### The point of no return

A shipped parcel or a wire transfer cannot be undone. Mark that step with `flow.pivot`. Before the pivot, a failure
compensates everything. After it, steps cannot declare `undo:` and are retried with backoff
(`config.after_pivot_attempts`, 25 by default). If they still fail, the execution is **blocked** for a human.

### Sleeping and waiting

`flow.sleep` writes the wake-up time in the notebook and releases the worker. `flow.wait_for` does the same until
a signal arrives:

```ruby
kyc = flow.wait_for(:kyc_done, timeout: 2.hours)

# in the webhook controller
Durable.signal("loan-42", :kyc_done, verified: true)
```

Signals can arrive before the saga starts waiting. Pass `id:` to `Durable.start` to address an execution by a name
you choose (the call is then idempotent).

### The recipe-changed alarm

If you change a recipe while executions are in flight, a replay may reach a step the notebook did not record.
Instead of guessing, ActiveDurable blocks that execution with `ActiveDurable::RecipeChanged`, naming the step it
expected and the one it found. The same happens if code outside a step reads data that changed between runs.

### Statuses

`pending`, `running`, `sleeping` and `waiting` are active. `completed`, `compensated` and `blocked` are final.
A blocked execution needs a person: its `error` column says why.

## Testing

```ruby
require "active_durable/testing"

it "survives a crash anywhere" do
  ActiveDurable::Testing.crash_everywhere(:checkout, order_id: order.id) do |execution, point|
    expect(execution.status).to eq("completed")
    expect(FakeStripe.charges.size).to eq(1)
  end
end
```

`crash_everywhere` runs the saga once to find every crash point (before each step, after the call but before the
checkpoint, after the checkpoint, and the same for undos). Then it runs a fresh execution per point, kills it there,
and resumes it with a new worker. It is the fastest way to find a step that is not idempotent.

`ActiveDurable::Testing.drain(execution_id, signals: { name => payload })` runs an execution synchronously,
fast-forwarding sleeps, retries and expired leases. Call `ActiveDurable::Testing.reset!` before each test.

## Configuration

```ruby
# config/initializers/active_durable.rb
ActiveDurable.configure do |config|
  config.lease_duration = 5.minutes     # longer than your slowest step
  config.step_attempts = 3              # before the pivot, then compensate
  config.after_pivot_attempts = 25      # after the pivot, then block
  config.undo_attempts = 10             # then block
  config.backoff = ->(attempt) { [2**attempt, 3600].min } # or [5, 30, 300], or a number
  config.queue_name = :default
end
```

## Guarantees and limits

- A step runs **at least once**. With an idempotency key it has an effect once. `flow.transaction` runs exactly
  once because its change and its checkpoint commit together.
- One worker at a time per execution: claims and every write are fenced by a lease token.
- Sagas do not isolate each other: two sagas can see each other's intermediate states.
- The notebook must live in the same database as your data for `flow.transaction` to be atomic.

## Development

```bash
bundle install
bundle exec rspec                 # PostgreSQL (default)
DB=mysql bundle exec rspec        # MySQL 8+
DB=sqlite3 bundle exec rspec      # SQLite 3
bundle exec rubocop
```

The design notes (in Spanish) live in `docs/`.

## License

MIT. See [LICENSE.txt](LICENSE.txt).
