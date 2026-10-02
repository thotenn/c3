---
doc: architecture/02-data-model-and-persistence
repo: c3
kind: architecture
anchored_to: e99b2ae
generated: 2026-10-02
---
# Data model and persistence

C3 keeps all of its state in one SQLite database behind `lib/c3/repo.ex:C3.Repo`, which uses `Ecto.Adapters.SQLite3`. No process holds a session's state. Every write is a single transaction. A row lock on the thread serializes it, and atomic `UPDATE … RETURNING` counters number things. The database is the only source of truth. PubSub only signals that a new event exists, and a listener then queries the table.

## How it works

**One Repo, one transaction per write, events published after commit.** `lib/c3/repo.ex:C3.Repo` overrides `transaction/2`. In the outermost transaction it wraps the call in `lib/c3/events.ex:publish_after`. While the transaction runs, that function collects the highest `seq` appended for each session in the process dictionary. It broadcasts `{:c3_events, session_id, seq}` only if the result is `{:ok, _}`. A rollback or a raise drops the collected events. Nested calls (`in_transaction?()`) pass straight through to `super`, so only the outermost commit publishes. The event-feed doc covers the fan-out.

**No per-session GenServer.** Writes are serialized in two ways:
- **Thread row lock.** `lib/c3/threads.ex:lock_thread!` runs `update_all(set: [updated_at: now], inc: [lock_version: 1])` with `select`, which is an `UPDATE … RETURNING`. This makes the transaction a writer on the thread row before it reads anything else. On Postgres that would be a real row lock. On SQLite every writer is already serialized, because `default_transaction_mode: :immediate` is set in `config/dev.exs` and `config/runtime.exs`.
- **Atomic counters.** Session-wide sequence numbers are claimed with `UPDATE … SET n = n + 1 RETURNING n`, and the caller uses `n - 1`:
  - `next_agent_number`: `lib/c3/sessions.ex:add_agent!`
  - `next_thread_number`: `lib/c3/threads.ex:next_thread_number!`
  - `event_seq`: `lib/c3/events.ex:append!`
  
  The counter moves in the same transaction as the row it numbers, so a rollback leaves no gap. This is how `seq` grows without gaps (`lib/c3/events/event.ex:C3.Events.Event`).
- **Message numbers are the exception.** `lib/c3/threads.ex:next_message_number!` computes `max(number) + 1`. This is safe only because the thread is locked first.

**Stored vs. derived.** `threads.status` is a cache. The pure function `lib/c3/threads/derivation.ex:derive` computes it from the thread's requests, and `lib/c3/threads.ex` recomputes it and writes it back in the same transaction as every write that touches a request. The `thread.status_changed` event is emitted only when the value changes. `awaiting` and `processing_by` are never stored. They are computed every time, appear in event payloads, and have no column.

**CHECKs are the real invariants; changesets mirror them.** Enums and the "this column is set exactly when…" rules are SQL `CHECK`s in the migrations. `lib/c3/schema.ex:validate_present_iff` mirrors a CHECK of the form `(field IS NOT NULL) = condition` inside a changeset, so a violation becomes a changeset error instead of a raised constraint error.

**IDs.** Every table has an internal integer `id`. The API exposes sessions by `code`, agents by `name` (`AGn`), threads by `number`, and messages by `thread_number.number`. The attachment `id` is the only internal id that reaches clients: `lib/c3_web/controllers/v1/thread_json.ex` (`id: a.id`) and the MCP argument `attachment_id` in `lib/c3_web/mcp/tools.ex`.

## The pieces

### Tables

| Table | Schema module (owner feature) | Key columns | Constraints / indexes worth knowing |
|---|---|---|---|
| `sessions` | `lib/c3/sessions/session.ex:C3.Sessions.Session` (sessions-and-agents, session-lifecycle) | `code`, `secret_hash`, `status`, counters `next_agent_number`/`next_thread_number`/`event_seq`, `joins_locked_at`, `last_activity_at`, `expires_at`, `closed_at`, `close_reason` | unique `code`; `sessions_closed_at_check` `(closed_at IS NOT NULL) = (status = 'closed')`; `close_reason IN ('manual','idle','max_ttl','admin')`; indexes `(status, last_activity_at)`, `(status, expires_at)` and `(status, closed_at)` for the reaper sweeps |
| `agents` | `lib/c3/sessions/agent.ex:C3.Sessions.Agent` (sessions-and-agents) | `session_id`, `number`, `name`, `label`, `token_hash`, `status`, `alerts_seen_seq`, `joined_ip` | unique `(session_id, number)`, `(session_id, name)` and global unique `token_hash`; `status IN ('active','left','revoked')`; `left_at` mirrored in the changeset only, with no CHECK |
| `threads` | `lib/c3/threads/thread.ex:C3.Threads.Thread` (threads-and-requests) | `number`, `title`, `opened_by_agent_id`, `status` (cache), `finished_at`, `last_message_at`, `lock_version` | unique `(session_id, number)`; `threads_finished_at_check` |
| `messages` | `lib/c3/threads/message.ex:C3.Threads.Message` (threads-and-requests) | `kind`, `author_agent_id`, `to_target`/`to_agent_id`/`to_label`, `reply_to_message_id`, `request_state`, `claimed_by_agent_id` | one conditional CHECK per column (`messages_author_check`, `messages_to_target_check`, `messages_to_agent_check`, `messages_to_label_check`, `messages_request_state_check`, `messages_claimed_by_check`); NULLs folded with `COALESCE`; no `updated_at` |
| `events` | `lib/c3/events/event.ex:C3.Events.Event` (event-feed) | `seq`, `type`, `actor_agent_id`, `thread_id`, `message_id`, `payload` (JSON text) | unique `(session_id, seq)`; `events_type_check` enumerates every type |
| `join_failures` | `lib/c3/security/join_failure.ex:C3.Security.JoinFailure` (join-security) | `ip` (ban subject), `ip_full`, `reason`, `attempted_code` | `session_id` uses `on_delete: :nilify_all`, so failures outlive their session; index `(ip, inserted_at)` |
| `ip_bans` | `lib/c3/security/ip_ban.ex:C3.Security.IpBan` (join-security) | `ip`, `ip_full`, `reason`, `session_code` (text, not an FK), `banned_until`, `lifted_at` | `reason IN ('invalid_secret','unknown_code','admin')`; no foreign keys |
| `idempotency_keys` | `lib/c3/sessions/idempotency_key.ex:C3.Sessions.IdempotencyKey` (sessions-and-agents) | `agent_id`, `key`, `request_hash`, `response_status`, `response_body` | unique `(agent_id, key)`; index on `inserted_at` for expiry |
| `attachments` | `lib/c3/threads/attachment.ex:C3.Threads.Attachment` (attachments) | `message_id`, `filename`, `content_type`, `size_bytes`, `sha256`, `storage_key` | `storage_key` deliberately **not** unique (one row per target message that shares a file); content lives on disk |

### Code

| Path | Export | Role |
|---|---|---|
| `lib/c3/repo.ex` | `C3.Repo.transaction/2` | Publishes events after the outermost commit |
| `lib/c3/schema.ex` | `C3.Schema.__using__/1` | `use C3.Schema` gives `Ecto.Schema`, `Ecto.Changeset`, `:utc_datetime_usec` timestamps and `validate_present_iff/4` |
| `lib/c3/schema.ex` | `validate_present_iff/4` | Mirrors a conditional CHECK in a changeset |
| `priv/repo/migrations/20261001220000_add_request_cancelled_event.exs` | `C3.Repo.Migrations.AddRequestCancelledEvent` | Reference pattern for rebuilding `events` |
| `priv/repo/migrations/20261002120100_add_secret_rotated_event.exs` | `C3.Repo.Migrations.AddSecretRotatedEvent` | Second instance of the same rebuild |
| `priv/repo/migrations/20261002180000_add_ip_full.exs` | `C3.Repo.Migrations.AddIpFull` | Data migration that is self-contained and uses no app module |
| `priv/repo/seeds.exs` | — | The unmodified Phoenix stub; it seeds nothing |

## How a feature uses it

A schema module does `use C3.Schema` and mirrors its table's conditional CHECKs. A write wraps everything in `Repo.transaction` and appends its events inside that transaction:

```elixir
use C3.Schema
# in changeset/2:
|> validate_present_iff(:finished_at, &(get_field(&1, :status) == :finished), "when finished")
```

```elixir
Repo.transaction(fn ->
  thread = lock_thread!(thread_id, now)        # serialize first
  # … insert/update rows …
  Events.append!(session, :message_posted, …)  # published only after commit
end)
```

If you skip the mirror, a violation reaches SQLite and comes back as a raised `Ecto.ConstraintError` instead of `{:error, changeset}`. If you call `Events.append!` outside a transaction, the counter and the event are no longer atomic.

## Rules

1. **Lock the thread before you read it in a write.** `lib/c3/threads.ex:lock_thread!` must come first, otherwise `next_message_number!` and the status derivation race.
2. **Recompute `threads.status` in the same transaction as every request change.** If you don't, the cache drifts from the requests and no job repairs it.
3. **Never add `awaiting` or `processing_by` columns.** They are derived (`lib/c3/threads/derivation.ex:derive`), and storing them creates a second cache to keep in sync.
4. **Adding an event type takes two edits:** the `@types` list in `lib/c3/events/event.ex`, and a migration that rebuilds `events` with the new `events_type_check`. Copy `priv/repo/migrations/20261002120100_add_secret_rotated_event.exs`: create `events_new` with the original FK names (`events_session_id_fkey`, …), copy `@columns`, drop the old table, rename, and recreate the unique `(session_id, seq)` index. The `@base` list must be the **current** full list, including every type added since. If you forget the migration, the insert fails the CHECK at runtime. In `down`, delete the new type's rows before rebuilding, or the copy fails the old CHECK.
5. **Any CHECK change on another table needs the same rebuild.** SQLite cannot `ALTER` a CHECK. `events` was easy because nothing references it. `messages` and `threads` are referenced by `events`, `attachments` and `messages.reply_to_message_id`, so their FKs would have to move as well. That has not been done yet.
6. **A migration must not call app modules.** `AddIpFull` copies the CIDR logic inline so it keeps working however `C3.Security.CIDR` changes later.
7. **Expose no internal id other than `attachments.id`.** Everything else goes out by `code`, `name` or `number`.

## Gotchas

- **Transactions in test are deferred.** `config/test.exs` does not set `default_transaction_mode`, unlike dev (`config/dev.exs`) and prod (`config/runtime.exs`). Writer serialization that holds in prod is therefore not what the test suite runs under. Don't read concurrency guarantees off a green test run.
- **SQLite FK violations carry no constraint name.** `foreign_key_constraint/3` cannot map them, so they raise (`lib/c3/schema.ex` moduledoc). The calls stay in place for Postgres. Callers always set FKs from records they already loaded.
- **Postgres is only "portable", never used.** Comments in `lib/c3/schema.ex`, `lib/c3/threads.ex` and the rebuild migrations reason about Postgres, but the adapter is SQLite only and nothing runs on Postgres. On Postgres, the thread lock would be the thing that serializes writers. On SQLite the real serializer is `:immediate` mode.
- **The publish map lives in the process dictionary.** A transaction run in another process (a `Task` inside the transaction) would not publish its events.
- **`publish_after` only broadcasts on `{:ok, _}`.** A transaction function that returns something else after a successful commit commits its events without announcing them. Listeners only see them on the next poll or timeout.
- **`messages_claimed_by_check` accepts `done` with or without a claimer.** A request can be resolved without going through a claim.
- **`ip` is a ban subject, not an address.** For IPv6 it is the network (`…/prefix`). The exact address is in `ip_full`, which is nullable on old rows (`AddIpFull`).
- **`agents.token_hash` is unique across all sessions**, not per session.
- The original design's `schema.md`, cited in the moduledocs and migration comments, is not in this repository: _(undetermined)_ where it lives.

## Who uses it

| Feature | Uses it for |
|---|---|
| sessions-and-agents | `sessions`, `agents`, `idempotency_keys`; the `next_agent_number` counter |
| session-lifecycle | `sessions.status`/`expires_at`/`last_activity_at` indexes for close sweeps |
| threads-and-requests | `threads`, `messages`; thread lock, status cache, `next_thread_number` |
| event-feed | `events`, `event_seq`, publish-after-commit in `C3.Repo` |
| join-security | `join_failures`, `ip_bans`, `ip`/`ip_full` |
| attachments | `attachments`; the one exposed internal id |
| admin-ui | Admin PubSub topic fed by the same post-commit broadcast |
