---
doc: features/admin-ui/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Admin UI — files

The admin UI has three layers. `lib/c3/admin.ex` is a thin context. Most of its actions delegate to `C3.Sessions`, `C3.Threads` and `C3.Security`. On top of it sit two LiveViews in `lib/c3_web/live/admin/` and two plain controllers: login, and attachment download. What surprises people is that the login gate is not in this feature's files. `C3Web.AdminAuth` (`lib/c3_web/admin_auth.ex`) and the `C3Web.Plugs.AdminEnabled` plug own it, and the router's `:admin` pipeline wires them in. With `C3_ADMIN_TOKEN` unset, `lib/c3/admin.ex:enabled?` is false and every `/admin` route is a 404. There are no admin users: whoever holds the token is the admin. Also, the attachment download is a controller, not a LiveView, so it has its own guard: `plug :require_admin` in `lib/c3_web/controllers/admin_attachment_controller.ex`.

**Owned globs:** `lib/c3/admin.ex`, `lib/c3_web/live/admin/*.ex`, `lib/c3_web/controllers/admin_session_controller.ex`, `lib/c3_web/controllers/admin_session_html.ex`, `lib/c3_web/controllers/admin_session_html/new.html.heex`, `lib/c3_web/controllers/admin_attachment_controller.ex`

## LiveViews

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/live/admin/session_live.ex` | `C3Web.Admin.SessionLive` | liveview | one session live: agents, threads, the selected thread's messages, the event log; close/unlock/finish/revoke/purge actions | adding a per-session admin action, changing what the detail page shows, or when a new event type has to refresh a panel |
| `lib/c3_web/live/admin/sessions_live.ex` | `C3Web.Admin.SessionsLive` | liveview | front page: every session still in the DB plus the IP bans in force, with unban | adding a column or stat to the session list, or changing the ban table |
| `lib/c3_web/live/admin/components.ex` | `C3Web.Admin.Components` | component | status badges, times, byte sizes, one-line event summaries | adding a new event type (its summary goes in `lib/c3_web/live/admin/components.ex:event_summary`), or adding a new status value |

Traps:
- `lib/c3_web/live/admin/session_live.ex:@agent_types` and `lib/c3_web/live/admin/session_live.ex:@thread_types` decide which event types reload which panel. A new event type that changes agents or threads must be added to them, or the page shows stale data until the next `@tick_ms` (30 s).
- `SessionLive` subscribes with `C3.Events.subscribe_admin` *before* its first read. On each `{:c3_events, id, seq}` announcement it fetches the events after the last `seq` it has shown (`lib/c3_web/live/admin/session_live.ex:fetch_events`), and reloads at most once per `@debounce_ms`. `SessionsLive` works differently: it never reads events. It only marks itself stale (`lib/c3_web/live/admin/sessions_live.ex:schedule`) and reloads everything, debounced at 1 s.
- `/sessions/:code` and `/sessions/:code/threads/:number` are both `SessionLive`. Selecting a thread is a `push_patch` handled in `lib/c3_web/live/admin/session_live.ex:handle_params`, not a separate LiveView. An unknown thread number patches back to the session.
- A purge, whether from this tab or broadcast as `{:c3_admin, {:purged, id}}`, navigates away to `/admin`. So does a session that disappears during `lib/c3_web/live/admin/session_live.ex:reload_session`.

## Contexts

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3/admin.ex` | `C3.Admin` | context | admin reads (`list_sessions`, `get_session`, `list_threads`, `get_thread`) and actions, all done as the `admin` actor | adding an admin action, or adding an aggregate to the session list |
| `lib/c3/admin.ex` | `C3.Admin.valid_token?` / `fingerprint` / `valid_login?` | context | the token check (constant-time), the HMAC fingerprint stored in the login cookie, and login TTL validity | changing how admin logins expire or what rotating the token voids |

Traps:
- `lib/c3/admin.ex:list_sessions` uses raw `CASE WHEN` SQL fragments over the status strings. Renaming an `Ecto.Enum` value for agent or thread status silently breaks the counts.
- `lib/c3/admin.ex:get_session` normalizes the code like a join does. A malformed code returns `nil`, not an error.
- `lib/c3/admin.ex:unban` and `lib/c3/admin.ex:purge_session` write no session event. They announce `{:unbanned, ip}` / `{:purged, id}` through `Events.notify_admin` only, so agents and watchers never see them.
- Rotating `C3_ADMIN_TOKEN` changes `lib/c3/admin.ex:fingerprint`, and that logs out every open browser.

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/admin_session_controller.ex` | `C3Web.AdminSessionController` | controller | `GET/POST /admin/login`, `DELETE /admin/logout`; per-IP rate limit on login attempts | changing the login form flow, the login rate limit, or the failure response |
| `lib/c3_web/controllers/admin_session_html.ex` | `C3Web.AdminSessionHTML` | view | embeds the login template | — |
| `lib/c3_web/controllers/admin_session_html/new.html.heex` | `new` | template | the token form | restyling the login page |
| `lib/c3_web/controllers/admin_attachment_controller.ex` | `C3Web.AdminAttachmentController.show` | controller | `GET /admin/sessions/:code/attachments/:id`, sent with the same headers an agent gets | changing how the admin downloads a file |

Traps:
- A wrong token returns `401` and logs `"Failed admin login from #{ip}"`. The limit key is `{:admin_login, ip}` in `lib/c3_web/controllers/admin_session_controller.ex:create`. A POST without the `login` param is handled as an empty token, not a 400.
- The attachment controller reuses `C3Web.V1.AttachmentController.send_attachment/2`. Download headers are owned by [attachments](../attachments/02-files.md); don't fork them here. A missing session and an attachment from another session both return a plain 404.

## Tests

| Path | Covers |
|---|---|
| `test/c3/admin_test.exs` | token, fingerprint and TTL access rules; `list_sessions` counts; close, revoke, unban and purge semantics; every committed event also announced on the admin topic; the F8 actions |
| `test/c3_web/live/admin_live_test.exs` | login (404 when disabled, bad token, logout); the sessions list and unban; the session detail page and its actions |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3_web/admin_auth.ex` | `C3Web.AdminAuth`, the login cookie and `on_mount(:require_admin)`: [architecture · auth](../../architecture/03-authentication-and-authorization.md) |
| `lib/c3_web/plugs/admin_enabled.ex` | the 404 gate when no admin token is set: architecture auth doc |
| `lib/c3_web/router.ex` | the `:admin` pipeline and `live_session :admin`: architecture request-pipeline doc |
| `lib/c3/sessions.ex` | close, unlock and revoke: [sessions-and-agents](../sessions-and-agents/02-files.md), [session-lifecycle](../session-lifecycle/02-files.md) |
| `lib/c3/threads.ex` | `admin_finish` and the derived thread states: [threads-and-requests](../threads-and-requests/02-files.md) |
| `lib/c3/events.ex` | the `admin` topic and `notify_admin`: [event-feed](../event-feed/02-files.md) |
| `lib/c3/security.ex` | bans and `list_active_bans`: [join-security](../join-security/02-files.md) |
| `lib/c3_web/controllers/v1/attachment_controller.ex` | `send_attachment/2`: [attachments](../attachments/02-files.md) |
