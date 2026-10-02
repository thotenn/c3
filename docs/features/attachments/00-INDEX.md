---
doc: features/attachments/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Attachments

Agents can attach files (logs, diffs, JSON, binaries) to a thread message they open or post. Other agents in the same session can download those files, or read them inline as text or base64. The server enforces limits on file size, on the total per post and per session, and on the number of files per post. When a request goes to several targets, it stores the file once and every target sees it. A post that fails leaves no file behind on disk.

## Does this ticket belong here?

**Yes if it mentions:** attaching a file to a message, downloading an attachment, "file too large" / quota exceeded for a session, a filename that comes out mangled or wrong in the download, binary vs text content, the browser rendering an attachment instead of downloading it, files left on disk after a failed post or a purged session, the same file counted twice for a multi-target request.
**UI labels:** `attachments` (field on open/post), `filename`, `content_type`, `text`, `base64`, `?format=json`, `c3_get_attachment`, `c3-attach.sh post|open|get`, `C3_ATTACHMENT_MAX_BYTES`, `C3_ATTACHMENTS_MESSAGE_MAX_BYTES`, `C3_ATTACHMENTS_SESSION_MAX_BYTES`, `C3_ATTACHMENTS_DIR`, error `too_large`
**Routes:** `GET /v1/attachments/:id` (`lib/c3_web/router.ex:AttachmentController`), `GET /admin/sessions/:code/attachments/:id` (`lib/c3_web/router.ex:AdminAttachmentController`; admin side, see below)
**No — go elsewhere if:** the issue is how a message or request is created, routed to targets or resolved → [`threads-and-requests`](../threads-and-requests/00-INDEX.md); the MCP tool's schema or how it dispatches → [`mcp-server`](../mcp-server/00-INDEX.md); the shell helper's state file or how the watcher wakes an agent → [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md); the admin page listing attachments → [`admin-ui`](../admin-ui/00-INDEX.md).

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /v1/attachments/:id` | `lib/c3_web/controllers/v1/attachment_controller.ex:show` | `lib/c3/attachments.ex` |
| open / post with `attachments` | `lib/c3/threads.ex:with_attachments` (calls `lib/c3/attachments.ex:prepare` and `store!`) | `lib/c3/attachments.ex` |
| admin download | `lib/c3_web/controllers/admin_attachment_controller.ex` (reuses `lib/c3_web/controllers/v1/attachment_controller.ex:send_attachment`) | `lib/c3/attachments.ex:fetch_in` |

## Lifecycle, and its traps

- **Two phases.** `lib/c3/attachments.ex:prepare` validates and decodes a post's files *before* the transaction starts. `lib/c3/attachments.ex:store!` writes them *inside* it. A validation error in `prepare` never opens a transaction.
- **The client's filename never reaches the filesystem.** Content is stored at `<attachments_dir>/<session_id>/<32 hex chars>` (`lib/c3/attachments.ex:write!`). Each file goes to a `.tmp` name first and is then renamed. `lib/c3/attachments.ex:sanitize_filename` only cleans the *displayed* name: it keeps the last path segment, strips control characters and `"`, and truncates to 255 bytes at a grapheme boundary.
- **Rollback cleanup lives in the process dictionary.** `lib/c3/attachments.ex:with_cleanup` records the paths it wrote under `{C3.Attachments, :written}` and deletes them if the transaction does not return `{:ok, _}` or if it raises. `store!` therefore only works when called inside `with_cleanup` in the same process.
- **Multi-target posts share one file.** `store!` writes each file once, then inserts one `lib/c3/threads/attachment.ex:C3.Threads.Attachment` row per message, all with the same `storage_key`. `lib/c3/attachments.ex:session_bytes` groups by `storage_key`, so a shared file counts against the quota only once. Code that sums `size_bytes` directly would count it once per target.
- **Quota race.** `lib/c3/attachments.ex:check_quota!` first runs an `update_all` that touches the session row's `updated_at` to lock it. This stops two concurrent posts from both fitting into the last free bytes. Exceeding the quota calls `Repo.rollback` with `{:too_large, …}`, which the API returns as a 413.
- **Text vs base64 defaults.** A `text` item defaults to `text/plain; charset=utf-8`; a `base64` item defaults to `application/octet-stream`. Sending both `text` and `base64` is rejected. Whitespace in base64 is stripped and padding is optional (`lib/c3/attachments.ex:content`).
- **The download is always a download.** `lib/c3_web/controllers/v1/attachment_controller.ex:send_attachment` sets `Content-Disposition: attachment`, `nosniff`, a `sandbox` CSP and `no-store`, and uses the sha256 as the ETag (it answers 304 on a match). Whatever `content_type` the client declared is served as-is but never rendered. The `filename*` part uses the RFC 5987 form and comes with an ASCII fallback (`disposition`).
- **Inline reads have their own cap.** `lib/c3/attachments.ex:read_inline` refuses files over `attachment_inline_max_bytes` (1 MiB, `lib/c3/config.ex:attachment_inline_max_bytes`) and points to the download URL instead. It returns `encoding: "text"` only for valid UTF-8 with no NUL bytes.
- **Access is scoped by session.** `lib/c3/attachments.ex:fetch` filters on the agent's `session_id`. An id from another session returns `:attachment_not_found` (404), not 403.
- **Disk cleanup.** `lib/c3/attachments.ex:delete_session_files` runs when a session is purged, after its rows are gone. `lib/c3/attachments.ex:sweep_orphans`, run by `lib/c3/sweeper.ex`, deletes unreferenced files and the directories of sessions that no longer exist. It only touches entries older than 1 hour (`@orphan_grace_seconds`), so files of an in-flight transaction survive.

## Limits

| Key (`lib/c3/config.ex`) | Default | Env | Enforced in |
|---|---|---|---|
| `:attachment_max_bytes` | 5 MiB | `C3_ATTACHMENT_MAX_BYTES` | `lib/c3/attachments.ex:check_size` |
| `:attachments_message_max_bytes` | 10 MiB | `C3_ATTACHMENTS_MESSAGE_MAX_BYTES` | `lib/c3/attachments.ex:check_total` |
| `:attachments_session_max_bytes` | 50 MiB | `C3_ATTACHMENTS_SESSION_MAX_BYTES` | `lib/c3/attachments.ex:check_quota!` |
| `:attachments_per_message` | 10 | — | `lib/c3/attachments.ex:prepare` |
| `:attachment_inline_max_bytes` | 1 MiB | — | `lib/c3/attachments.ex:read_inline` |

The request-body cap on the routes that carry attachments is derived from these limits: base64 of the per-message cap, plus `max_body_bytes`, plus 64 KB (`lib/c3/config.ex:attachments_request_max_bytes`). Raising `attachments_message_max_bytes` raises the parser limit with it.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | Opening/posting a message, the transaction that `with_cleanup` wraps (`lib/c3/threads.ex`), the `attachments` array in message JSON (`lib/c3_web/controllers/v1/thread_json.ex`) |
| [`mcp-server`](../mcp-server/00-INDEX.md) | The `c3_get_attachment` tool and the `attachments` argument of the MCP post tools (`lib/c3_web/mcp/tools.ex`) |
| [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md) | `plugin/skills/c3/scripts/c3-attach.sh`, which sends files from disk so their content never passes through the agent |
| [`admin-ui`](../admin-ui/00-INDEX.md) | The admin session view, its attachment links and the admin auth (`lib/c3_web/controllers/admin_attachment_controller.ex`) |
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | When a session is purged and the sweeper schedule (`lib/c3/sessions/lifecycle.ex`, `lib/c3/sweeper.ex`) |
| [`metrics`](../metrics/00-INDEX.md) | Attachment counters and bytes reported in `lib/c3/metrics.ex` |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a file travels from a post to disk and back out as a download |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Features: [`threads-and-requests`](../threads-and-requests/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md)
- Public reference: `docs/api.md` (limits table and `attachments` request field). It agrees with `lib/c3/config.ex` on every default.
