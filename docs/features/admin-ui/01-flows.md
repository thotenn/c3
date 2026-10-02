---
doc: features/admin-ui/01-flows
repo: c3
kind: feature-flows
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Admin UI — flows

The admin UI has six flows. Two are plain controller requests: logging in and out, and downloading an attachment. Two are LiveView pages kept current by the `admin` PubSub topic: the sessions index and the single-session view. The other two are the admin actions. Session-scoped actions (close, unlock joins, finish thread, revoke, purge) run on the session page. Unban runs on the index. Each action calls the same domain function as its automatic twin, so it leaves the same events behind (`lib/c3/admin.ex:C3.Admin`). There are no admin users. Whoever holds `C3_ADMIN_TOKEN` is the admin, and when that variable is unset every `/admin` route returns 404 (`lib/c3_web/plugs/admin_enabled.ex`).

## Flow: Log in / log out

**Entry:** `GET /admin/login`, `POST /admin/login`, `DELETE /admin/logout`

1. **Trigger**: the admin submits the token form (`login[token]`) · `lib/c3_web/controllers/admin_session_controller.ex:create`
2. **Guard**: the `:admin` pipeline returns 404 while the token is unset (`lib/c3_web/plugs/admin_enabled.ex`). The login is then capped at `@login_limit` (10) tries per minute per IP through `RateLimiter.hit({:admin_login, ip}, …)`. Going over the cap returns 429 with `retry-after` · `lib/c3_web/controllers/admin_session_controller.ex:@login_limit`
3. **Logic**: the token is trimmed, then compared in constant time · `lib/c3/admin.ex:valid_token?`
4. **Persist**: the cookie stores a fingerprint of the token (an HMAC of it) plus the login time, never the token itself · `lib/c3_web/admin_auth.ex:log_in`, `lib/c3/admin.ex:fingerprint`
5. **Notify**: `Logger.info` on success and `Logger.warning("Failed admin login …")` on failure. No PubSub message.
6. **Respond**: redirect to `/admin`, or re-render `:new` with 401. `new` skips the form when a login is already valid. `delete` drops the whole cookie session · `lib/c3_web/controllers/admin_session_controller.ex:new`, `lib/c3_web/admin_auth.ex:log_out`

**Touch this flow when:** changing how the admin authenticates, the login TTL, or the login rate limit.
**Breaks when:** the admin token is rotated. The fingerprint stops matching, so every existing login is void (`lib/c3/admin.ex:valid_login?`). A login also expires after `admin_session_ttl`, and a stored timestamp in the future is rejected (`at <= now`). A POST without a `login` key falls through to an empty token and returns 401, not a 400 (`lib/c3_web/controllers/admin_session_controller.ex:create`).

## Flow: Watch every session (index page)

**Entry:** `live "/admin"` → `C3Web.Admin.SessionsLive`

1. **Trigger**: the admin opens `/admin` · `lib/c3_web/live/admin/sessions_live.ex:mount`
2. **Guard**: `on_mount {C3Web.AdminAuth, :require_admin}` on the `:admin` live_session · `lib/c3_web/admin_auth.ex:on_mount`
3. **Logic**: one aggregate query returns each session with its agent and thread counts, ordered by `status` desc and then `last_activity_at` desc. Rows include closed sessions still within retention · `lib/c3/admin.ex:list_sessions`
4. **Persist / call**: bans in force come from `lib/c3/admin.ex:list_active_bans`, and counters come from `C3.Metrics.snapshot()`. Both are read inside `lib/c3_web/live/admin/sessions_live.ex:load`
5. **Notify**: subscribes to the `admin` topic. Every `{:c3_events, …}` or `{:c3_admin, …}` message only marks the page stale, and the page reloads at most once per `@debounce_ms` (1 s). A `:tick` every 30 s also reloads it · `lib/c3_web/live/admin/sessions_live.ex:schedule`
6. **Render**: a sessions table linking to `/admin/sessions/:code`, metric tiles built by `stat`, and the bans table · `lib/c3_web/live/admin/sessions_live.ex:render`

**Touch this flow when:** adding a column or count to the session list, or a metric tile.
**Breaks when:** a new count is added to the `select` without `coalesce`, so sessions with no agents or threads show `nil`. The `CASE WHEN` fragments compare the raw stored strings (`'active'`, `'pending'`, `'processing'`), so renaming an enum value silently zeroes the count (`lib/c3/admin.ex:list_sessions`). Every reload re-runs the full query for every session.

## Flow: Inspect one session live

**Entry:** `live "/admin/sessions/:code"` and `live "/admin/sessions/:code/threads/:number"` → `C3Web.Admin.SessionLive`

1. **Trigger**: the admin opens a session, or patches to one of its threads · `lib/c3_web/live/admin/session_live.ex:mount`, `lib/c3_web/live/admin/session_live.ex:handle_params`
2. **Guard**: the same `on_mount` as the index. The code is normalized the way a join normalizes it, and an unknown code produces a flash plus a redirect to `/admin` · `lib/c3/admin.ex:get_session`
3. **Logic**: the page subscribes to the `admin` topic *before* the first read. It loads the latest `@page` (100) events, the agents, and the threads with their derived state · `lib/c3/admin.ex:list_threads`. A selected thread loads its messages · `lib/c3/admin.ex:get_thread`
4. **Persist / call**: on `{:c3_events, id, seq}` for this session with `seq > last_seq`, `fetch_events` pages through `Events.list_after`. Events are inserted at the top, and each one's type marks `:agents`, `:threads` or `:selected` as stale (`@agent_types`, `@thread_types`) · `lib/c3_web/live/admin/session_live.ex:fetch_events`
5. **Notify**: one `:reload` per `@debounce_ms` (300 ms) refreshes the session row and only the stale parts. A `:tick` every 30 s reloads the session and agents, because `last_seen_at` and `last_activity_at` change without emitting an event · `lib/c3_web/live/admin/session_live.ex:handle_info`
6. **Render**: header, agents table, thread list, message pane, and event log with "Load older events" (`load_older`). Event lines come from `lib/c3_web/live/admin/components.ex:event_summary`

**Touch this flow when:** adding a new event type, or changing what the session page shows.
**Breaks when:** a new `C3.Events.Event` type is added without a clause in `lib/c3_web/live/admin/components.ex:event_summary`. That function's `case` has no fallback, so rendering the event crashes the LiveView. A new type that affects agents or threads but is missing from `@agent_types` / `@thread_types` leaves those panels stale until the next tick (agents) or indefinitely (threads). A missing session row on reload (purged) navigates away to `/admin` · `lib/c3_web/live/admin/session_live.ex:reload_session`. A `:number` that does not parse as an integer patches back to the session page with an error flash.

## Flow: Act on a session (close, unlock joins, finish thread, revoke, purge)

**Entry:** `phx-click` events `close_session`, `unlock_joins`, `finish_thread`, `revoke`, `purge_session` on `C3Web.Admin.SessionLive`

1. **Trigger**: the admin clicks a button and confirms the `data-confirm` prompt · `lib/c3_web/live/admin/session_live.ex:handle_event`
2. **Guard**: buttons only render when the action applies. Close and unlock need an `:open` session (unlock also needs `joins_locked_at`). Purge needs a `:closed` session. Finish needs an open session and an unfinished selected thread. Revoke needs an `:active` agent. The domain checks again and returns `{:error, :session_closed}`, `{:ok, false}`, `{:ok, %{changed: false}}`, `{:error, :not_active}` or `{:error, :not_closed}`, which become flashes.
3. **Logic**: delegates to the domain twin with `"admin"` as the actor · `lib/c3/admin.ex:close_session`, `lib/c3/admin.ex:unlock_joins`, `lib/c3/admin.ex:finish_thread`, `lib/c3/admin.ex:revoke_agent`, `lib/c3/admin.ex:purge_session`
4. **Persist / call**: `close_session` runs `Sessions.close_session!` inside `Repo.transaction`. Purge calls `C3.Sessions.Lifecycle.purge_session/1`, the same delete the retention job uses. `revoke` looks up the agent by string id in `Sessions.list_agents` and does not trust the client.
5. **Notify**: close, unlock, finish and revoke emit normal session events. Those reach this page and agents' watchers through the event feed. Purge leaves no row to hold an event, so it broadcasts `{:c3_admin, {:purged, id}}` · `lib/c3/admin.ex:purge_session`
6. **Respond**: a flash plus a local assign or stream refresh. Purge navigates to `/admin`, and any other admin tab open on that session follows via `handle_info({:c3_admin, {:purged, id}}, …)`.

**Touch this flow when:** adding an admin action, or changing what an admin close or revoke does to agents.
**Breaks when:** an action is implemented directly in the LiveView instead of through `C3.Admin`. It then skips the domain's event and watcher `stop` handling and leaves a different trace than the agent-side twin. `finish_thread` with nothing selected is a silent no-op (`handle_event("finish_thread", _params, socket)`).

## Flow: Lift an IP ban

**Entry:** `phx-click="unban"` with `phx-value-ip` on `C3Web.Admin.SessionsLive`

1. **Trigger**: the admin clicks Unban on a row · `lib/c3_web/live/admin/sessions_live.ex:handle_event`
2. **Guard**: only the LiveView's `on_mount` admin check. Any IP string is accepted.
3. **Logic / persist**: `C3.Security.unban/1` sets `lifted_at` and evicts the IP from `BanCache` · `lib/c3/admin.ex:unban`
4. **Notify**: `{:c3_admin, {:unbanned, ip}}` on the admin topic. A ban is per IP, so no session event is written.
5. **Respond**: a flash ("Lifted the ban of …" or "… was not banned.") and a reload of the index.

**Touch this flow when:** changing ban semantics as seen by the operator.
**Breaks when:** _(undetermined)_. Note that the action lifts every ban for that IP, not just the clicked row.

## Flow: Download an attachment as admin

**Entry:** `GET /admin/sessions/:code/attachments/:id` → `C3Web.AdminAttachmentController.show`

1. **Trigger**: the admin clicks an attachment link in the message pane · `lib/c3_web/live/admin/session_live.ex:render`
2. **Guard**: `plug :require_admin`. This route is outside the live_session, so the controller needs its own guard · `lib/c3_web/controllers/admin_attachment_controller.ex:show`, `lib/c3_web/admin_auth.ex:require_admin`
3. **Logic**: resolves the session by code, then loads the attachment scoped to that session with `Attachments.fetch_in(session.id, id)`, so an id from another session returns 404.
4. **Respond**: reuses `C3Web.V1.AttachmentController.send_attachment/2`, so the admin gets the same headers as an agent. Any failure returns a plain `404 Not found`.

**Touch this flow when:** changing download headers (change them in the shared `send_attachment`) or adding another admin-only file route (it must add `require_admin` itself).
**Breaks when:** the plug is removed. `AdminEnabled` alone does not check the login.

## Shared state

- **`admin` PubSub topic**: `C3.Events.subscribe_admin/0` / `notify_admin/1` and the `{:c3_events, session_id, seq}` announcements are owned by [event-feed](../event-feed/). Both LiveViews only consume them.
- **Session, agent and thread state**: closing, revoking, unlocking and purging belong to [sessions-and-agents](../sessions-and-agents/), [join-security](../join-security/) and [session-lifecycle](../session-lifecycle/). Finishing a thread belongs to [threads-and-requests](../threads-and-requests/).
- **Bans and `BanCache`**: owned by [join-security](../join-security/).
- **Metrics snapshot** shown on the index: owned by [metrics](../metrics/).
- **Attachment storage and `send_attachment`**: owned by [attachments](../attachments/).
- **Admin cookie session** (fingerprint plus login time) and the `AdminEnabled` plug: `lib/c3_web/admin_auth.ex` and `lib/c3_web/plugs/admin_enabled.ex`, which sit outside this feature's files.
