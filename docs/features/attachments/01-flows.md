---
doc: features/attachments/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Attachments — flows

This feature has four flows. Two are user-visible. In the first, an agent attaches files to a post (open a thread or post a message). In the second, an agent or the admin reads a file back, either as a download or inline as JSON. The other two are housekeeping: deleting a session's files when the session is purged, and sweeping orphaned files off disk. The write flow is split around the database transaction. Validation and decoding run before it (`lib/c3/attachments.ex:prepare`). The quota check and the disk writes run inside it (`lib/c3/attachments.ex:store!`). Files written by a transaction that rolls back are removed (`lib/c3/attachments.ex:with_cleanup`).

## Flow: attach files to a thread or a message

**Entry:** `POST` open-thread / post-message with an `attachments` array (REST and `/mcp`). See [threads-and-requests](../threads-and-requests/01-flows.md).

1. **Trigger** — The caller sends `[{filename, content_type?, text | base64}]`. `C3.Threads` passes `attrs["attachments"]` to prepare before it opens the transaction · `lib/c3/threads.ex:open_thread`, `lib/c3/threads.ex:post_message`
2. **Guard** — The checks run in this order:
   - the file count against `attachments_per_message`;
   - for each item: the filename is valid UTF-8, then it is sanitized to its last path segment, with control characters and quotes removed, at most 255 bytes, and `.`/`..` rejected;
   - the item has `text` or `base64`, not both;
   - the decoded size against `attachment_max_bytes`;
   - `content_type` must match `@content_type`;
   - the summed size against `attachments_message_max_bytes`.

   Code: `lib/c3/attachments.ex:prepare`, `lib/c3/attachments.ex:sanitize_filename`, `lib/c3/attachments.ex:check_total`
3. **Logic** — The default content type is `text/plain; charset=utf-8` for `text` and `application/octet-stream` for `base64`. Whitespace inside base64 is stripped and padding is optional. A sha256 is computed for each file · `lib/c3/attachments.ex:prepare_one`
4. **Persist** — Inside `with_cleanup` + transaction, `store!` takes a write lock on the session row with a no-op `updated_at` update, then checks the session quota. The quota counts each `storage_key` once, so a file sent to several targets counts once. Going over calls `Repo.rollback({:too_large, …})` · `lib/c3/attachments.ex:check_quota!`, `lib/c3/attachments.ex:session_bytes`
5. **Write** — Each file is written once to `<attachments_dir>/<session_id>/<128 random bits hex>` through a `.tmp` file and a rename. The path is recorded in the process dictionary for cleanup. Then one `Attachment` row is inserted per (message × file): a post to N targets gives N rows that share one `storage_key` · `lib/c3/attachments.ex:write!`, `lib/c3/threads/attachment.ex:changeset`
6. **Respond** — The message JSON carries the `attachments` metadata. If the transaction result is not `{:ok, _}`, or if it raises, every file written in it is deleted · `lib/c3/attachments.ex:with_cleanup`

**Touch this flow when:** you change a limit, add an accepted field to an attachment item, change the filename or content-type rules, or change how multi-target posts share files.

**Breaks when:**
- `store!` is called outside `with_cleanup`. `Process.get(@written)` is then unset and the `[path | nil]` list breaks, or files leak on rollback.
- The request body is larger than `lib/c3/config.ex:attachments_request_max_bytes`. The parser rejects it before any of the checks above run.
- The base64 is invalid, which gives `422`. A size limit gives `413` (`{:too_large, _}`).

## Flow: download or inline-read an attachment

**Entry:** `GET /v1/attachments/:id` (agent token), `?format=json` (used by `c3_get_attachment`); admin `GET /sessions/:code/attachments/:id` · `lib/c3_web/router.ex`

1. **Trigger** — Agent: `lib/c3_web/controllers/v1/attachment_controller.ex:show`. Admin: `lib/c3_web/controllers/admin_attachment_controller.ex` (it reuses `send_attachment`).
2. **Guard** — The lookup is scoped to the session. A wrong session, an unknown id or a non-integer id all give `:attachment_not_found` (404), so nothing reveals whether the id exists · `lib/c3/attachments.ex:fetch`, `lib/c3/attachments.ex:fetch_in`
3. **Logic (json)** — Files over `attachment_inline_max_bytes` give `{:too_large, …}`, and the message points to the download URL. Otherwise the content is returned as `text` if it is valid UTF-8 without NUL bytes, else as `base64` · `lib/c3/attachments.ex:read_inline`
4. **Logic (download)** — The response always carries:
   - `Content-Disposition: attachment`, with an ASCII fallback plus `filename*` per RFC 5987;
   - `nosniff`;
   - CSP `default-src 'none'; sandbox`;
   - `private, no-store`;
   - an ETag equal to the sha256.

   A matching `If-None-Match` gets a `304` · `lib/c3_web/controllers/v1/attachment_controller.ex:send_attachment`
5. **Respond** — The file is sent from `lib/c3/attachments.ex:path` with the stored `content_type`. The JSON variant merges in `C3Web.V1.ThreadJSON.attachment/1` (`lib/c3_web/controllers/v1/thread_json.ex`).

**Touch this flow when:** you change download headers or security policy, the inline size cap, or text/base64 detection, or you add another reader such as an MCP tool.

**Breaks when:** the file is missing on disk while its row still exists. `File.read!` raises in `read_inline`, and `send_file` fails.

## Flow: purge a session's files

**Entry:** session purge in `lib/c3/sessions/lifecycle.ex` (see [session-lifecycle](../session-lifecycle/01-flows.md)).

1. **Persist** — After the rows are gone, the lifecycle calls `delete_session_files`, which `rm_rf`s `<attachments_dir>/<session_id>` · `lib/c3/attachments.ex:delete_session_files`

**Breaks when:** the delete is skipped because the purge transaction failed. Any leftovers are then handled by the orphan sweep.

## Flow: sweep orphaned files

**Entry:** `C3.Sweeper` tick (`lib/c3/sweeper.ex`), which reports `attachment_orphans_deleted`.

1. **Logic** — For each numeric directory under `attachments_dir`:
   - if the session no longer exists, the whole directory is removed once its mtime is more than 1 hour old;
   - otherwise, files that no `storage_key` points at are removed once they are more than 1 hour old.

   Code: `lib/c3/attachments.ex:sweep_orphans`
2. **Guard** — The 1-hour grace period is `@orphan_grace_seconds`. It protects files that belong to a post still inside its transaction. Leftover `.tmp` files fall into the unreferenced case.

**Touch this flow when:** you change the storage layout or `storage_key` format. The sweep matches on `"#{session_id}/#{file}"`.

## Shared state

- Limits and `attachments_dir`: `lib/c3/config.ex` (configuration document).
- The session row lock and the message transaction belong to `C3.Threads` ([threads-and-requests](../threads-and-requests/01-flows.md)).
- `current_agent` auth on `/v1`: [sessions-and-agents](../sessions-and-agents/01-flows.md). The admin route's auth: [admin-ui](../admin-ui/01-flows.md).
- `docs/api.md` puts the 413 for an attachment limit under `too_large`, which matches `{:too_large, _}` here.
