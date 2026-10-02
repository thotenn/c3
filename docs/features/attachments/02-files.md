---
doc: features/attachments/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Attachments — files

Attachments live in three files: one context that handles the whole lifecycle (validate, write, read, purge), one schema, and one download controller. The surprising part is that **nothing here creates an attachment by itself**. Files come in inline on the open and post calls of `lib/c3/threads.ex`. That code calls `lib/c3/attachments.ex:prepare/1` before its transaction, and calls `lib/c3/attachments.ex:store!/4` inside a transaction wrapped by `lib/c3/attachments.ex:with_cleanup/1`. The second surprise is in the data. A post to several targets writes **one file on disk** but inserts **one row per request**, and every row shares the same `storage_key` (`lib/c3/threads/attachment.ex:storage_key`). Quota and metrics therefore group by `storage_key`, not by row (`lib/c3/attachments.ex:session_bytes`).

**Owned globs:** `lib/c3/attachments.ex`, `lib/c3/threads/attachment.ex`, `lib/c3_web/controllers/v1/attachment_controller.ex`

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/attachments.ex` | `C3.Attachments.prepare/1` | context | validates and decodes `[{filename, content_type?, text \| base64}]` before the transaction; enforces the per-file, per-post and file-count limits | changing what a valid attachment looks like, or adding a new per-post limit |
| `lib/c3/attachments.ex` | `C3.Attachments.store!/4` | context | locks the session row (an `update_all` on `updated_at`), checks the session quota, writes each file once, inserts one row per message | changing the session quota, or how a multi-target post shares its files |
| `lib/c3/attachments.ex` | `C3.Attachments.with_cleanup/1` | context | deletes the files written in this process when the wrapped transaction does not return `{:ok, _}` or raises | a new code path that stores attachments outside `open`/`post` |
| `lib/c3/attachments.ex` | `C3.Attachments.sanitize_filename/1` | util | keeps the last path segment, strips control characters and `"`, caps at 255 bytes, rejects `.`/`..` | a report of an odd filename in a download |
| `lib/c3/attachments.ex` | `C3.Attachments.fetch/2`, `fetch_in/2` | context | reads one attachment scoped to a session; anything else is `{:error, :attachment_not_found}` | changing who may read an attachment |
| `lib/c3/attachments.ex` | `C3.Attachments.read_inline/1` | context | content for a JSON answer: `text` if the bytes are valid UTF-8 with no NUL, otherwise `base64`; refused above `attachment_inline_max_bytes` | changing what `c3_get_attachment` / `?format=json` returns |
| `lib/c3/attachments.ex` | `C3.Attachments.path/1` | util | `storage_key` → path under `C3.Config.attachments_dir/0` | moving the storage location or layout |
| `lib/c3/attachments.ex` | `C3.Attachments.delete_session_files/1` | context | `rm_rf` of `<dir>/<session_id>`; call it only after the session's rows are deleted | changing session purge |
| `lib/c3/attachments.ex` | `C3.Attachments.sweep_orphans/1` | context | deletes files with no row, and directories of sessions that no longer exist, once they are older than `@orphan_grace_seconds` (1 h) | orphan files pile up, or the grace window needs to change |

Traps:
- The on-disk name is `<session_id>/<128 random bits hex>`, written to `.tmp` and then renamed (`lib/c3/attachments.ex:write!`). It is never built from the client's filename, so keep it that way.
- `with_cleanup/1` keeps the list of written files in the process dictionary (`lib/c3/attachments.ex:@written`). A `store!/4` call made from a different process than the wrapper does not get cleaned up.
- The file-count limit comes from `Config.get(:attachments_per_message)` in `lib/c3/attachments.ex:prepare/1`, but it has no environment variable (`lib/c3/config.ex:attachments_per_message`). `docs/api.md` calls it "fixed", which matches in practice.
- Errors use the `C3.Threads` shapes `{:invalid, msg, details}` (422) and `{:too_large, msg}` (413). The quota check runs inside the transaction, so it fails through `Repo.rollback/1` (`lib/c3/attachments.ex:check_quota!`).

## Schemas

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/threads/attachment.ex` | `C3.Threads.Attachment` | schema | metadata row (`filename`, `content_type`, `size_bytes`, `sha256`, `storage_key`), belongs to `message` and `session`; no `updated_at` | adding a field to the attachment metadata |
| `lib/c3/threads/attachment.ex` | `changeset/2` | schema | requires every field, filename 1–255 bytes, `size_bytes >= 0`, with the `attachments_size_check` constraint | changing row validation |

`session_id` is stored on the row, not derived through the message, so that `fetch/2` and the quota can scope by session with one query. The table itself comes from a migration under `priv/`, which is outside this feature's source roots.

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/v1/attachment_controller.ex` | `C3Web.V1.AttachmentController.show/2` | controller | `GET /v1/attachments/{id}` for the token's session; `?format=json` merges `C3Web.V1.ThreadJSON.attachment/1` with the result of `read_inline/1` | changing the download endpoint or the inline JSON |
| `lib/c3_web/controllers/v1/attachment_controller.ex` | `send_attachment/2` | controller | always a download: `Content-Disposition: attachment` (ASCII fallback plus RFC 5987 `filename*`), `nosniff`, `default-src 'none'; sandbox`, `private, no-store`, ETag = sha256, and a 304 on `If-None-Match` | changing download headers. This also changes the admin download, which calls it |

These headers exist so that stored HTML or SVG is never rendered in the browser, whatever `content_type` the client declared. Do not relax them for one caller.

## Tests

| Path | Covers |
|---|---|
| `test/c3/attachments_test.exs` | `prepare/1` decoding, limits and filename sanitizing; a multi-target post writes one file and N rows; the session quota counts each file once; a failed post leaves no file; `fetch/2` session scoping; `read_inline/1` text, base64 and limit; purge and `sweep_orphans/1` |
| `test/c3_web/controllers/v1/f8_controller_test.exs` | (`describe "attachments"`) HTTP round trip: posted inline, listed on the message, downloaded with headers; other sessions get 404; 413 / 422 mapping |
| `test/c3_web/mcp/parity_test.exs` | `c3_get_attachment` matches the REST answer |
| `test/c3/attach_script_test.exs` | the plugin's `plugin/skills/c3/scripts/c3-attach.sh` upload helper |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3/threads.ex` (open/post, which call `prepare`/`store!`/`with_cleanup`; the `attachments` names in event payloads) | `threads-and-requests` |
| `lib/c3_web/controllers/v1/thread_json.ex:attachment` (metadata JSON on messages) | `threads-and-requests` |
| `lib/c3/config.ex:attachments_request_max_bytes`, `lib/c3/config.ex:attachments_dir` (limits, storage dir) | configuration |
| `lib/c3_web/plugs/parsers.ex` (larger body cap on routes that carry attachments) | request pipeline |
| `lib/c3/sessions/lifecycle.ex` (calls `delete_session_files/1` after purge) | `session-lifecycle` |
| `lib/c3/sweeper.ex` (schedules `sweep_orphans/1`) | [architecture · processes](../../architecture/04-processes-and-background-work.md) |
| `lib/c3_web/controllers/admin_attachment_controller.ex`, `lib/c3_web/live/admin/session_live.ex` | `admin-ui` |
| `lib/c3_web/mcp/tools.ex` (`c3_get_attachment`, the `attachments` input schema) | `mcp-server` |
| `lib/c3/metrics.ex` (`c3_attachments_bytes`) | `metrics` |
| `lib/c3_web/controllers/v1/fallback_controller.ex` (`:attachment_not_found` → 404) | request pipeline |
| `plugin/skills/c3/scripts/c3-attach.sh` | `watcher-and-plugin` |
