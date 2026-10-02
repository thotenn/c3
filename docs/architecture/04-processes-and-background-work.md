---
doc: architecture/04-processes-and-background-work
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Processes and background work

C3 runs as one flat OTP supervision tree. Durable state lives in the database. A few named GenServers own ETS tables that act as fast caches or counters. One periodic process, `C3.Sweeper`, runs the maintenance jobs that keep sessions, claims and leftovers bounded. Phoenix PubSub only sends "something changed" hints, so long-polls and LiveViews wake up and re-read the tables.

## How it works

**Supervision tree.** `lib/c3/application.ex:start` first calls `C3.Config.validate!()`, so a bad configuration crashes the boot before any child starts. It then starts a single `:one_for_one` supervisor named `C3.Supervisor` with these children, in this order:

```
C3.Supervisor (one_for_one)
├── C3Web.Telemetry            (Supervisor → :telemetry_poller, 10 s period)
├── C3.Repo
├── Ecto.Migrator              (skip: true unless RELEASE_NAME is set)
├── DNSCluster                 (:ignore when no dns_cluster_query)
├── Phoenix.PubSub  name: C3.PubSub
├── C3.Security.BanCache       (GenServer + ETS)
├── C3.RateLimiter             (GenServer + ETS)
├── C3.Idempotency             (GenServer + ETS)
├── C3.Metrics                 (GenServer + ETS + telemetry handler)
├── C3.Sweeper                 (only when C3.Config.get(:sweeper) is truthy)
└── C3Web.Endpoint
```

When `:sweeper` is false, the `C3.Config.get(:sweeper) && C3.Sweeper` entry evaluates to `false`, and `Enum.filter(children, & &1)` removes it. `lib/c3/application.ex:skip_migrations?` runs migrations at boot only inside a release.

**What the design planned but the code does not have.** There is no GenServer per session, no `DynamicSupervisor`, no `Registry` and no `Phoenix.Presence` in `lib/` (absent). Those were dropped. A session is a set of rows and nothing else: no process starts when a session opens or stops when it closes, and nothing per session has to be restarted.

**The sweeper.** `lib/c3/sweeper.ex:init` schedules a `:sweep` message every `sweep_interval_ms` (one minute by default). `lib/c3/sweeper.ex:handle_info` calls `lib/c3/sweeper.ex:run`, which runs these jobs in order and returns a map of counts:

| Key | Job |
|---|---|
| `claims_expired` | `C3.Threads.expire_claims/1` — claims of silent agents go back to open |
| `sessions_warned` | `C3.Sessions.Lifecycle.warn_closing/1` — the `closing_soon` warning |
| `sessions_closed` | `C3.Sessions.Lifecycle.close_expired/1` — idle / max_ttl close |
| `sessions_purged` | `C3.Sessions.Lifecycle.purge/1` |
| `idempotency_keys_purged` | `C3.Idempotency.purge/1` — keys older than a day |
| `security_purged` | `C3.Security.purge_history/1` |
| `attachment_orphans_deleted` | `C3.Attachments.sweep_orphans/1` — files with no row behind them |

`handle_info` wraps the whole pass in one `rescue` that logs the error. If one job raises, the jobs after it are skipped for that tick, but the process survives and reschedules. Warnings run before closes, so a session that is already past its close gets no warning: it is just closed (see the `lib/c3/sweeper.ex` moduledoc).

**Timers outside the sweeper.** Two processes run their own sweeps:
- `lib/c3/security/ban_cache.ex:handle_info` runs every hour (`@sweep_ms`).
- `lib/c3/rate_limiter.ex:handle_info` runs every minute (`schedule_sweep`).

Neither starts or stops with the `:sweeper` flag.

**In-memory state, lost on restart.** Each of these processes creates a `:named_table, :public` ETS table in its `init`:

| Owner | Table holds | On restart |
|---|---|---|
| `lib/c3/security/ban_cache.ex:init` | IP → ban end, a mirror of `ip_bans` | rebuilt by `lib/c3/security/ban_cache.ex:load` in `handle_continue(:load, …)` |
| `lib/c3/rate_limiter.ex:init` | rate-limit windows | gone: every limit starts again from zero |
| `lib/c3/idempotency.ex:init` | in-flight marks (`begin/2` … `finish/2`) | gone; stored responses stay in the DB (`lib/c3/idempotency.ex:store`) |
| `lib/c3/metrics.ex:init` | counters fed by `[:c3, …]` telemetry events | gone: `/metrics` counters reset |

The tables are public, so callers read and write them directly from their own processes. The GenServer only owns the table and sweeps it. If the owner crashes, the table dies with it, and `one_for_one` restarts only that owner.

**Fan-out.** `lib/c3/events.ex:publish_after` wraps an outermost `C3.Repo.transaction/2`. While the transaction runs, it collects the highest `seq` for each session in the process dictionary. After `{:ok, _}`, `lib/c3/events.ex:broadcast` sends one `{:c3_events, session_id, seq}` per session, both to `"session:<id>"` and to the admin topic. A rollback or a raise sends nothing. An append outside a transaction broadcasts immediately. `lib/c3/events.ex:notify_admin` sends `{:c3_admin, message}` for changes that leave no event row, such as a lifted ban or a purged session.

**Telemetry.** `lib/c3_web/telemetry.ex:metrics` declares the stock Phoenix, `c3.repo.query.*` and VM summaries, but no reporter is attached: the `ConsoleReporter` line is commented out. `periodic_measurements` is empty. C3's own counters come from `C3.Metrics`, which attaches a `:telemetry` handler (`"c3-metrics"`) and does not go through `C3Web.Telemetry`.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/application.ex` | `start/2` | Validates the config, then builds the flat tree; the sweeper is conditional |
| `lib/c3/sweeper.ex` | `run/1` | Runs every periodic job once at a given `now`; this is what tests call |
| `lib/c3/sweeper.ex` | `handle_info/2` | The timer tick; logs failures and always reschedules |
| `lib/c3/security/ban_cache.ex` | `load/0`, `put/2`, `banned_until/2`, `delete/1` | ETS mirror of `ip_bans`; reloads at boot, sweeps hourly |
| `lib/c3/rate_limiter.ex` | `hit/3` | ETS windows; sweeps every minute |
| `lib/c3/idempotency.ex` | `begin/2`, `finish/2`, `purge/1` | In-flight marks in ETS; `purge/1` is a sweeper job |
| `lib/c3/metrics.ex` | `emit/2`, `snapshot/0`, `prometheus/0` | Telemetry-fed ETS counters |
| `lib/c3/events.ex` | `publish_after/1`, `subscribe/1`, `subscribe_admin/0`, `notify_admin/1` | PubSub fan-out |
| `lib/c3_web/telemetry.ex` | `metrics/0` | Phoenix/Repo/VM metric definitions with no reporter attached |

## How a feature uses it

To add a periodic job, add a key to `lib/c3/sweeper.ex:run` that calls a function taking `now`. To react to changes, subscribe and then re-read the table:

```elixir
:ok = C3.Events.subscribe(session)
receive do
  {:c3_events, _session_id, _seq} -> # re-query events after your cursor
end
```

If you do not take `now` as a parameter, a test cannot drive the job, because the sweeper process never runs in test.

## Rules

1. A periodic job must take `now` and be callable directly. With `sweeper: false` in `config/test.exs` the timer never runs in test, so tests call `C3.Sweeper.run/1` or the job itself. A job that reads the clock on its own cannot be tested.
2. Treat a PubSub message as a hint, never as the data. The message carries only the highest `seq`, and messages are not replayed. A subscriber that trusts the payload misses intermediate events, and it misses everything sent while it was not subscribed.
3. Append events inside `C3.Repo.transaction/2` so announcements wait for the commit. Otherwise a listener can wake up, read, and find nothing yet.
4. Keep the database as the source of truth for anything in ETS that must survive a restart. Only the ban cache is rebuilt at boot; anything else you put in ETS is lost on restart.
5. A sweeper job must not raise for a routine condition. One raise skips every job after it for that tick.

## Gotchas

- The comment in `lib/c3/application.ex` says the sweeper "expires silent claims and old idempotency keys". It also closes, purges and deletes attachment orphans. The moduledoc in `lib/c3/sweeper.ex` is the accurate list.
- The ban-cache and rate-limiter sweeps are not sweeper jobs. They do run in test, and `sweeper: false` does not stop them.
- `Ecto.Migrator` is skipped outside a release. In dev and test, migrations come from `mix`, not from the boot.
- The admin topic receives every session's `{:c3_events, …}` and also `{:c3_admin, …}`. An admin subscriber must handle both shapes.
- `C3Web.Telemetry.metrics/0` looks like live instrumentation, but nothing consumes it. The Prometheus output comes from `C3.Metrics`.
- `C3.Metrics` counters and rate-limit windows reset on every deploy. A fresh boot is enough to wipe rate-limit state.
- This is one node's state. The ETS tables and the single sweeper are per node: running more than one node duplicates the sweeps and splits the rate limits _(multi-node behaviour undetermined)_.

## Who uses it

| Feature | Uses it for |
|---|---|
| Event feed / long-poll | `C3.Events.subscribe/1` wake-ups |
| Admin UI | `subscribe_admin/0`, `notify_admin/1` |
| Session lifecycle | sweeper warn / close / purge |
| Threads (claims) | sweeper `expire_claims` |
| Security (bans, join limits) | `C3.Security.BanCache`, `C3.RateLimiter`, `purge_history` |
| Idempotency | in-flight ETS marks, sweeper purge |
| Attachments | sweeper `sweep_orphans` |
| Metrics endpoint | `C3.Metrics` counters |
