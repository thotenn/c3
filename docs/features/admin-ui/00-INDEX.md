---
doc: features/admin-ui/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: e99b2ae
generated: 2026-10-02
---
# Admin UI

A browser console for whoever runs the C3 server. The operator signs in with the admin token and gets a live list of every session with server-wide counters and the IP bans in force. From a session's page they can see its agents, threads, messages and event log as they change. They can also act on it: close the session, revoke an agent, let new agents join again, finish a thread, purge a closed session, lift a ban, and download an attachment.

## Does this ticket belong here?

**Yes if it mentions:** the admin page, the dashboard, the operator console, admin login/logout, "invalid admin token", too many login attempts, the admin being logged out after the token was rotated, the sessions list or its counters, a session's page not updating live, the event log on the admin page ("load older"), closing/purging a session or revoking an agent "from the admin", unbanning an IP from the UI, downloading an attachment as the admin.
**UI labels:** `Admin`, `Admin token`, `Sign in`, `Sessions`, `Open sessions`, `Active agents`, `Bans in force`, `Attachments`, `Sessions created`, `Sessions closed`, `Failed joins`, `Bans issued`, `Banned until`, confirmations such as `Close this session for every agent? This cannot be undone.`, `Let new agents join this session again?`, `Delete this session and everything in it now? This cannot be undone.`; env var `C3_ADMIN_TOKEN`.
**Routes:** `/admin/login`, `/admin/logout`, `/admin`, `/admin/sessions/:code`, `/admin/sessions/:code/threads/:number`, `/admin/sessions/:code/attachments/:id`
**No — go elsewhere if:**
- the admin action works but has the wrong effect (what a close, revoke, or finish does to agents and watchers) → [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`threads-and-requests`](../threads-and-requests/00-INDEX.md)
- why an IP got banned or a session got locked → [`join-security`](../join-security/00-INDEX.md)
- the counters show wrong numbers → [`metrics`](../metrics/00-INDEX.md)
- an event is missing or arrives twice → [`event-feed`](../event-feed/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /admin/login`, `POST /admin/login` | `lib/c3_web/controllers/admin_session_controller.ex:new`, `:create` (template `lib/c3_web/controllers/admin_session_html/new.html.heex`) | `lib/c3/admin.ex` |
| `DELETE /admin/logout` | `lib/c3_web/controllers/admin_session_controller.ex:delete` | `lib/c3/admin.ex` |
| `/admin` | `lib/c3_web/live/admin/sessions_live.ex:C3Web.Admin.SessionsLive` | `lib/c3_web/live/admin/` |
| `/admin/sessions/:code`, `/admin/sessions/:code/threads/:number` | `lib/c3_web/live/admin/session_live.ex:C3Web.Admin.SessionLive` | `lib/c3_web/live/admin/` |
| `GET /admin/sessions/:code/attachments/:id` | `lib/c3_web/controllers/admin_attachment_controller.ex:show` | `lib/c3/admin.ex` |

## Traps

- **Without `C3_ADMIN_TOKEN`, every `/admin` route is a 404**, and that includes the login page (`lib/c3/admin.ex:enabled?`). A ticket saying "/admin is not found" is usually a configuration problem, not a bug.
- **The login cookie holds a fingerprint, not the token** (`lib/c3/admin.ex:fingerprint`): changing the token logs out every admin. A login also expires after `admin_session_ttl` (`lib/c3/admin.ex:valid_login?`).
- **The login is rate limited twice**: `@login_limit` tries per minute per IP (`lib/c3_web/controllers/admin_session_controller.ex:create`, answers 429 with `retry-after`), on top of the per-IP limit on every `/admin` route. A wrong token gets a 401.
- **Every admin action reuses the domain function behind its automatic twin** (`lib/c3/admin.ex:close_session`, `:revoke_agent`, `:finish_thread`, `:unlock_joins`, `:purge_session`). Change what an action *does* there, not in the LiveView. `unban` and `purge_session` leave no session event behind, so they announce on the admin topic instead (`{:c3_admin, {:unbanned, ip}}`, `{:c3_admin, {:purged, id}}`).
- **Live updates are debounced, not one query per event.** `SessionsLive` only marks itself stale and reloads after `@debounce_ms` 1 000 ms. `SessionLive` streams the events themselves, and their types (`@agent_types`, `@thread_types`) decide which panels reload after `@debounce_ms` 300 ms. If a panel stays stale after a new event type, add the type to those lists. Both pages also reload on a 30 s `@tick_ms`, for `last_seen_at` and `last_activity_at`, which change without an event.
- **The session page subscribes before its first read** (`lib/c3_web/live/admin/session_live.ex:mount`), the same pattern the watcher uses. Reversing the order loses events.
- If the open session is purged, its page redirects to `/admin` (`lib/c3_web/live/admin/session_live.ex:handle_info`).
- The attachment download sends the same headers an agent gets, through `C3Web.V1.AttachmentController.send_attachment/2`. A missing session or attachment is a plain-text 404 (`lib/c3_web/controllers/admin_attachment_controller.ex:show`).

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | closing, retention and purge semantics (`C3.Sessions.Lifecycle`) |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | revoke and unlock-joins behaviour |
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | finishing a thread and its derived state |
| [`join-security`](../join-security/00-INDEX.md) | bans, their reasons and durations, `C3.Security.unban/1` |
| [`event-feed`](../event-feed/00-INDEX.md) | the event log, `{:c3_events, id, seq}` announcements, `list_after` and `list_recent` |
| [`metrics`](../metrics/00-INDEX.md) | the values on the front page counters |
| [`attachments`](../attachments/00-INDEX.md) | storing and serving attachment bytes |
| Architecture: authentication | `C3Web.AdminAuth` and `C3Web.Plugs.AdminEnabled`: the plug and on_mount guard themselves |

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a login, an admin action and a live update travel from the browser to the database and back |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Architecture: [`03-authentication-and-authorization.md`](../../architecture/03-authentication-and-authorization.md), [`01-request-pipeline-and-routing.md`](../../architecture/01-request-pipeline-and-routing.md), [`05-configuration-and-environments.md`](../../architecture/05-configuration-and-environments.md)
- Features: [`session-lifecycle`](../session-lifecycle/00-INDEX.md), [`join-security`](../join-security/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`metrics`](../metrics/00-INDEX.md)
