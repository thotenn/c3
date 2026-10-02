---
doc: architecture/02-data-model-and-persistence
repo: c3
kind: architecture
anchored_to: fcd0bd9
generated: 2026-10-02
---
# The SQLite schema, the Repo, and writing a migration

C3 stores everything in one SQLite database through `lib/c3/repo.ex:C3.Repo`, which uses the `Ecto.Adapters.SQLite3` adapter. There are nine tables, and each one has a single schema module. Every schema module gets its setup from `lib/c3/schema.ex:C3.Schema`. The design has no per-session process. Writes are serialized by the database itself: one transaction, a row lock on the thread, and atomic `UPDATE … RETURNING` counters. Events appended during a write are only announced over PubSub after the outermost transaction commits.

## How it works

**Tables.** One table per entity. The migrations live in `priv/repo/migrations/`. Every timestamp is `utc_datetime_usec`, which `lib/c3/schema.ex:__using__` sets through `@timestamps_opts`. Append-only tables (`messages`, `events`, `join_failures`, `ip_bans`, `idempotency_keys`, `attachments`) have no `updated_at` column.

| Table | Schema module | Key columns | CHECKs / indexes worth knowing |
|---|---|---|---|
| `sessions` | `lib/c3/sessions/session.ex` | `code` (unique), `secret_hash`, `status`, `next_agent_number`, `next_thread_number`, `event_seq`, `expires_at`, `closed_at`, `close_reason` | `sessions_closed_at_check`: `(closed_at IS NOT NULL) = (status = 'closed')`. `close_reason IN ('manual','idle','max_ttl','admin')`. Three `[status, …]` indexes exist for the reapers. |
| `agents` | `lib/c3/sessions/agent.ex` | `session_id`, `number`, `name`, `label`, `token_hash` (unique), `status` (`active`/`left`/`revoked`), `alerts_seen_seq` | Unique `[session_id, number]` and `[session_id, name]`. In the changeset, `left_at` is required once the agent is no longer active. |
| `threads` | `lib/c3/threads/thread.ex` | `session_id`, `number`, `title`, `opened_by_agent_id`, `status`, `finished_at`, `last_message_at`, `lock_version` | `threads_finished_at_check`: `(finished_at IS NOT NULL) = (status = 'finished')`. Unique `[session_id, number]`. |
| `messages` | `lib/c3/threads/message.ex` | `thread_id`, `session_id`, `number`, `kind`, `author_agent_id`, `to_target`/`to_agent_id`/`to_label`, `reply_to_message_id`, `request_state`, `claimed_by_agent_id` | Six conditional CHECKs, one per column, with NULLs folded by `COALESCE`: a system message has no author; only requests have `to_target` and `request_state`; `claimed_by_agent_id` must be set when `claimed`, may be either when `done`, and must be NULL otherwise. |
| `events` | `lib/c3/events/event.ex` | `session_id`, `seq`, `type`, `actor_agent_id`, `thread_id`, `message_id`, `payload` (JSON text, default `{}`) | `events_type_check` is a closed list of types. Unique `[session_id, seq]`. |
| `join_failures` | `lib/c3/security/join_failure.ex` | `ip`, `reason`, `session_id` (`nilify_all`), `attempted_code` | `reason IN ('invalid_secret','unknown_code','session_closed','joins_locked')` |
| `ip_bans` | `lib/c3/security/ip_ban.ex` | `ip`, `reason`, `session_code` (text, not an FK), `banned_until`, `lifted_at` | `reason IN ('invalid_secret','unknown_code','admin')`. No foreign key at all. |
| `idempotency_keys` | `lib/c3/sessions/idempotency_key.ex` | `agent_id`, `key`, `request_hash`, `response_status`, `response_body` | Unique `[agent_id, key]`. Indexed on `inserted_at` for pruning. |
| `attachments` | `lib/c3/threads/attachment.ex` | `message_id`, `session_id`, `filename`, `content_type`, `size_bytes`, `sha256`, `storage_key` | `size_bytes >= 0`. `storage_key` is **not** unique: a request sent to several targets becomes one message per target, and all of them point at the same file on disk. |

Deleting a session removes its agents, threads, messages, events, attachments and idempotency keys through `on_delete: :delete_all`. The FKs from `threads.opened_by_agent_id`, from the `messages.*_agent_id` columns and from the `events` actor/thread/message columns have no `on_delete` option.

**Stored vs derived.** `threads.status` is a **cache**. The real value comes from the pure function `lib/c3/threads/derivation.ex:derive`, computed from `finished_at` and the thread's requests. Every write recomputes and stores it inside the same transaction, through `lib/c3/threads.ex:refresh_threads!` and `apply_state!`. When the status moves, that same transaction appends a `thread.status_changed` event. `awaiting` and `processing_by` come out of the same derivation and are **never stored**. No column holds them.

**Serialization.** No GenServer owns a session (see `lib/c3/threads.ex:C3.Threads` moduledoc). A thread write runs in one transaction that starts with `lib/c3/threads.ex:lock_thread!`. That function is an `update_all(inc: [lock_version: 1])` with `select`, so it compiles to `UPDATE … RETURNING`, and it takes the thread's row lock. Counters are allocated the same way, with an atomic increment-and-return:

- `event_seq`: `lib/c3/events.ex:append!`
- `next_agent_number`: `lib/c3/sessions.ex`
- `next_thread_number`: `lib/c3/threads.ex:next_thread_number!`

Claims use a conditional `UPDATE … WHERE request_state = 'open'`. When two agents race, exactly one of them updates a row. In dev and prod, the repo config sets `default_transaction_mode: :immediate` (`config/dev.exs`, `config/runtime.exs`), so SQLite takes its write lock at `BEGIN`. `config/test.exs` does not set it, so test transactions are deferred and run under `Ecto.Adapters.SQL.Sandbox`.

**Publish after commit.** `lib/c3/repo.ex:transaction` overrides `transaction/2`. When no transaction is open, it wraps the call in `lib/c3/events.ex:publish_after`. That function collects the highest `seq` per session from the events appended inside the transaction. It broadcasts them only if the result is `{:ok, _}`, and drops them on a rollback or a raise. Nested calls (`in_transaction?/0`) go straight to `super`.

**Public identifiers.** Internal integer `id`s are not part of the external API. Sessions are addressed by `code`, agents by `number`/name, threads by `number`, and messages by `thread.number`.`message.number`. The one exception is the attachment id: `lib/c3_web/mcp/tools.ex` takes an integer `attachment_id`.

## The pieces

| Path | Export | Role |
|---|---|---|
| `lib/c3/repo.ex` | `C3.Repo.transaction/2` | Ecto repo on SQLite. Publishes events only after the outermost commit. |
| `lib/c3/schema.ex` | `C3.Schema.__using__/1` | `use Ecto.Schema`, `import Ecto.Changeset`, microsecond UTC timestamps |
| `lib/c3/schema.ex` | `C3.Schema.validate_present_iff/4` | Changeset mirror of a `(field IS NOT NULL) = condition` CHECK |
| `lib/c3/threads/derivation.ex` | `derive/2` | The pure status derivation that `threads.status` caches |
| `lib/c3/events.ex` | `append!/3`, `publish_after/1` | Allocates `seq`; defers the PubSub broadcast |
| `priv/repo/migrations/20261001220000_add_request_cancelled_event.exs` | `rebuild/1` | The template for changing `events_type_check` |
| `priv/repo/migrations/20261002120100_add_secret_rotated_event.exs` | `rebuild/1` | Second instance of the same rebuild |
| `priv/repo/seeds.exs` | — | The Phoenix default comment only. It seeds nothing. |

## How a feature uses it

A new schema writes `use C3.Schema` and mirrors each conditional CHECK in its changeset. Leaving the mirror out means a bad row surfaces as an `Ecto.ConstraintError` raise instead of a changeset error. From `lib/c3/threads/thread.ex`:

```elixir
use C3.Schema
# ...
|> validate_present_iff(:finished_at, &(get_field(&1, :status) == :finished), "when finished")
```

A write that has to be atomic calls `Repo.transaction(fn -> … end)` and calls `Events.append!` inside it. It never broadcasts by hand.

## Rules

1. **Never write `threads.status` without recomputing it from the requests in the same transaction.** Use `lib/c3/threads.ex:refresh_threads!`. A stale cache silently breaks status filters and the `[session_id, status]` index.
2. **Never store `awaiting` or `processing_by`.** They are derived on every read, and a stored copy would drift.
3. **Allocate counters with an atomic `update_all(inc: …)` plus `select`, never read-then-write.** In deferred-mode tests, two writers that read first would race onto the unique `[session_id, number]` or `[session_id, seq]` index.
4. **To add an event type, write a migration that rebuilds `events`.** SQLite cannot `ALTER` a CHECK. Copy `rebuild/1` from `priv/repo/migrations/20261002120100_add_secret_rotated_event.exs`, set `@base` to the *current* list, and have `down` delete the rows of the new type before rebuilding. Keep the explicit FK names (`events_session_id_fkey`, …). Otherwise they get named after `events_new`.
5. **Every conditional CHECK gets a `validate_present_iff` twin.** On SQLite, the constraint error carries no name to map back to a field.
6. **Keep SQL portable to Postgres.** Postgres is only a target to stay portable to; it is not configured or tested anywhere. The `foreign_key_constraint/3` calls are kept for that portability (see the `lib/c3/schema.ex:C3.Schema` moduledoc).

## Gotchas

- **Foreign key violations raise on SQLite.** They never become changeset errors, because SQLite gives no constraint name. Callers are expected to set FKs only from records they already loaded.
- **Only the outermost `Repo.transaction` publishes.** A nested transaction that "succeeds" announces nothing until the outer one commits. Code that calls `Ecto.Adapters.SQL` or `Repo.checkout` directly bypasses `publish_after`.
- **Tests do not use `:immediate`.** A lock-ordering bug that dev and prod hide by taking the write lock up front can show up only in tests as `database is locked`, or the other way round.
- **On SQLite, `lock_thread!` is a write lock, not a row lock.** Any write transaction already serializes the whole database. The per-row lock matters only on Postgres.
- **`messages` has one CHECK per column.** That is why the rules are split across `to_target`, `to_agent_id`, `to_label`, `request_state` and `claimed_by_agent_id`, rather than written as one table-level CHECK.
- **`ip_bans.session_code` is plain text, and `join_failures.session_id` is `nilify_all`.** Security history outlives the session it was about.
- **Attachment files are not rows.** Deleting a session removes the `attachments` rows by cascade. The bytes on disk are handled by `lib/c3/attachments.ex`, and `storage_key` is shared across rows.

## Who uses it

| Feature | Uses it for |
|---|---|
| Sessions and joining (`lib/c3/sessions.ex`) | `sessions`, `agents` and `idempotency_keys`; `next_agent_number`; close and reaping |
| Threads and requests (`lib/c3/threads.ex`) | Row lock, status cache, message numbering, claims |
| Event feed (`lib/c3/events.ex`) | `event_seq`, the `events` table, publish-after-commit |
| Security (`lib/c3/security/`) | `join_failures`, `ip_bans` |
| Attachments (`lib/c3/attachments.ex`) | `attachments` rows and the exposed attachment id |
| Admin (`lib/c3/admin.ex`) | Admin close, inside `Repo.transaction` |
