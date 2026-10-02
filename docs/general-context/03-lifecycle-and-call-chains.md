---
doc: general-context/03-lifecycle-and-call-chains
repo: c3
kind: general
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Lifecycle and call chains

C3 has no process per session. Every write is a single database transaction in a context module (`lib/c3/sessions.ex`, `lib/c3/threads.ex`). The transaction recomputes the thread's cached `status` before it commits and appends events through `lib/c3/events.ex:append!`, which takes the next `seq` from the session row inside that same transaction. `lib/c3/repo.ex:transaction` holds back the PubSub announcement until the outermost transaction commits, so a rollback announces nothing. Readers such as the long-poll, `/watch` and the admin LiveViews subscribe first, then query the table, and treat each announcement as "query again". The table is the source of truth and a PubSub message is only a hint. MCP tool calls get no separate code path: each one is re-dispatched through the REST router in-process.

## Boot

`lib/c3/application.ex:start` validates config and then starts its children in this order:

1. `lib/c3/config.ex:validate!` runs before any child starts, so a bad `C3_*` setting stops boot. See [configuration](../architecture/05-configuration-and-environments.md).
2. `C3Web.Telemetry`, then `C3.Repo`.
3. `Ecto.Migrator` runs the migrations, but only inside a release. `lib/c3/application.ex:skip_migrations?` skips them when `RELEASE_NAME` is unset (dev and test use mix).
4. `DNSCluster`, then `Phoenix.PubSub` named `C3.PubSub`. All event fan-out goes through `C3.PubSub`.
5. The ETS-backed servers: `lib/c3/security/ban_cache.ex`, `lib/c3/rate_limiter.ex`, `lib/c3/idempotency.ex`, `lib/c3/metrics.ex`.
6. `lib/c3/sweeper.ex:run` starts only when `C3.Config.get(:sweeper)` is set; it is off in test. It expires claims, warns, closes and purges sessions, purges idempotency keys, and sweeps orphan attachments.
7. `C3Web.Endpoint` starts last, so no request arrives before the Repo, PubSub and caches are up.

The supervisor is `:one_for_one`. Details are in [processes and background work](../architecture/04-processes-and-background-work.md).

## The invariant every write chain shares

| Step | Where | Trap |
|---|---|---|
| Transaction opens | `lib/c3/repo.ex:transaction` → `lib/c3/events.ex:publish_after` | Only the **outermost** call wraps `publish_after`. A nested call goes straight to `super`, so its events wait for the outer commit. |
| Thread row locked | `lib/c3/threads.ex:lock_thread!` | It is an `UPDATE` that bumps `lock_version`, not a `SELECT … FOR UPDATE`. SQLite already serializes writers. The lock exists so Postgres stays correct. |
| Event appended | `lib/c3/events.ex:append!` | Must run inside the caller's transaction: the `event_seq` increment and the event insert commit together. Called outside a transaction, it broadcasts immediately (`lib/c3/events.ex:notify`). |
| Status recomputed | `lib/c3/threads.ex:apply_state!` → `lib/c3/threads/derivation.ex` | Runs last in each thread write, after the request rows change. It appends `:thread_status_changed` only when the status actually changes. |
| Published | `lib/c3/events.ex:publish_after` → `broadcast` | Only on `{:ok, _}`, and only the highest `seq` per session. The message goes to `session:<id>` **and** to the `admin` topic. |

## Create and join a session

1. `lib/c3_web/router.ex` `post "/sessions"` / `post "/sessions/:code/join"` go through the `:v1` pipeline only: `lib/c3_web/plugs/real_ip.ex` and the per-IP `lib/c3_web/plugs/rate_limit.ex`. Neither route needs a token. Join does not use idempotency keys, because there is no `AgentAuth` yet.
2. `lib/c3_web/controllers/v1/session_controller.ex:create` / `join`.
3. `lib/c3/sessions.ex:create_session` checks the IP ban (`check_ban`) and the label, then generates and hashes the secret **outside** the transaction.
4. `lib/c3/sessions.ex:insert_session` opens the transaction and inserts the `Session` with a fresh code. If the code collides, the transaction rolls back and the insert is retried up to 3 times. It does not reuse a transaction after a constraint error, which Postgres would abort.
5. `lib/c3/sessions.ex:add_agent!` allocates the agent number with an atomic `next_agent_number` increment (`AG<n>`), stores only the token hash, and calls `lib/c3/events.ex:append!` with `:agent_joined`.
6. On a join, `lib/c3/sessions.ex:join_session` → `join_existing` verifies the secret **before** it opens a transaction, then calls the same `add_agent!`.
7. A bad secret takes `lib/c3/sessions.ex:invalid_secret` instead. That path records the failure, appends `:security_join_failed`, and may lock the session's joins (`maybe_lock_joins` → `:session_joins_locked`). An unknown code takes `lib/c3/sessions.ex:unknown_code`, which runs `Credentials.dummy_verify()` so timing does not reveal that the code is unknown.
8. After the commit, `:agent_joined` is announced. `lib/c3/watch.ex:relevant` turns it into a `joined` line only for `AG1`.

The clear secret and token exist only in the return value of steps 3 to 5. See [sessions and agents](../features/sessions-and-agents/00-INDEX.md) and [join security](../features/join-security/00-INDEX.md).

## Open thread → claim → answer → finish

Every route here goes through `:v1` + `:agent`: `lib/c3_web/plugs/agent_auth.ex:call`, then the per-token rate limit, then `lib/c3_web/plugs/idempotency.ex:call` on `POST`. `AgentAuth` returns 403 when the token belongs to another session, 410 when the session is closed, and 401 when the token was revoked. It also refreshes `touch_seen` and `touch_activity`. Controllers resolve `T<n>` with `lib/c3/threads.ex:fetch_thread` **before** the transaction opens.

**Open**

1. `lib/c3_web/controllers/v1/thread_controller.ex:create` → `lib/c3/threads.ex:open_thread`.
2. Outside the transaction: `check_body_size`, `lib/c3/attachments.ex:prepare`, `lib/c3/threads/targets.ex:resolve`.
3. `Attachments.with_cleanup` wraps `Repo.transaction`. Files written by a transaction that rolls back are removed.
4. The thread is inserted; its number comes from `next_thread_number!`. There is **no** `lock_thread!` here, because the row is new. `insert_requests!` creates one request message per target.
5. `lib/c3/attachments.ex:store!`, then `Events.append!(:thread_opened)`, which carries the targets and request refs. Then `apply_state!` recomputes the status, usually emitting `:thread_status_changed`.

**Claim**

1. `lib/c3_web/controllers/v1/thread_controller.ex:claim` → `lib/c3/threads.ex:claim`.
2. The transaction opens, then `lock_thread!`. A finished thread rolls back (`rollback_finished`).
3. A conditional `update_all … where request_state == :open` decides the race: exactly one agent changes the row. A claim that changes nothing and holds nothing rolls back with `{:conflict, …, %{claimed_by: …}}`, which becomes a 409. Claiming a request you already hold is a no-op.
4. One `:request_claimed` per claimed request, then `apply_state!`.

**Answer**

1. `lib/c3_web/controllers/v1/thread_controller.ex:post_message` → `lib/c3/threads.ex:post_message` with `kind: response`.
2. The transaction opens, then `lock_thread!`, then `fetch_reply_to!` and `next_message_number!`.
3. `resolvable!` finds what this response resolves. Without `reply_to`, that is every request addressed to the author. `insert_message!` writes the response. `resolve!` marks those requests done and claims any that nobody had claimed.
4. `:message_posted` carries `resolved` and `resolved_for`. `lib/c3/watch.ex:relevant` uses `resolved_for` to wake each requester with an `answer` line. Then `apply_state!`.

**Finish**

1. `lib/c3_web/controllers/v1/thread_controller.ex:finish` → `lib/c3/threads.ex:finish` → `finish_thread`. The admin path is `lib/c3/threads.ex:admin_finish`, which always forces.
2. The transaction opens, then `lock_thread!`, then `check_opened_by!`: only the agent that opened the thread can finish it. Finishing an already finished thread is a no-op that returns `changed: false`.
3. If requests are still pending and `force` is not set, it rolls back with a 409 listing them. With `force`, they are set to `:cancelled` and each one gets a `:request_cancelled` event. The holder learns to stop from this event.
4. `apply_state!` runs with the `finished_at` timestamp.

Background expiry follows the same pattern from the sweeper: `lib/c3/threads.ex:expire_claims` opens its own transaction per thread and appends `:request_claim_expired`. See [threads and requests](../features/threads-and-requests/00-INDEX.md).

## Long-poll and watch wake-up

1. The plugin's `plugin/skills/c3/scripts/c3-watch.sh` `poll` calls `GET …/watch?after=<cursor>&wait=<s>` with curl and saves the returned `cursor` after every poll. `save` sets the cursor to the session's current end (`current_end`), so a freshly saved watcher never reports old events.
2. The route goes through `[:sse, :feed]` in `lib/c3_web/router.ex`. In `:feed`, `AgentAuth` runs with `activity: false`, so polling does **not** postpone the session's idle close.
3. `lib/c3_web/controllers/v1/event_controller.ex:watch` caps `wait` at `long_poll_max_wait` and sets a deadline. `watch_after` then loops.
4. `lib/c3/events.ex:wait_after` calls `subscribe` **first**, and only then `list_after(seq > after)`. Anything committed before the query shows up in its result; anything committed after it arrives as a message. Nothing falls between the two.
5. If the query is empty, `lib/c3/events.ex:await` blocks in `receive`. It ignores announcements with `seq <= after` and re-queries on any other announcement. When the deadline passes it returns `[]`. A `:telemetry` `[:c3, :long_poll, :stop]` event records the outcome as `immediate`, `woken` or `timeout`.
6. The `after` block unsubscribes and flushes leftover messages (`lib/c3/events.ex:unsubscribe`).
7. `watch_after` maps each event through `lib/c3/watch.ex:line`. Events the agent caused itself are never reported back to it. If none of the events concern this agent, `watch_after` advances the cursor and waits again until the deadline. The response is `cursor <seq>` followed by `<kind> <seq> …` lines.
8. If the node dies between a commit and its publish, the waiter just times out. The next poll uses the same `after`, so the event is delivered then.

The JSON feed (`lib/c3_web/controllers/v1/event_controller.ex:index`) uses the same `wait_after`. See [event feed](../features/event-feed/00-INDEX.md) and [watcher and plugin](../features/watcher-and-plugin/00-INDEX.md).

## An MCP tool call

1. `lib/c3_web/router.ex` `post "/mcp"` goes through the `:mcp` pipeline: `lib/c3_web/plugs/origin.ex`, `RealIp`, and the per-IP rate limit. The pipeline has no `accepts`, so a legacy `GET` gets a 405 instead of a 406.
2. `lib/c3_web/controllers/mcp_controller.ex:post` → `lib/c3_web/mcp/server.ex:handle`, which handles JSON-RPC.
3. For `tools/call`, `lib/c3_web/mcp/server.ex:call` → `lib/c3_web/mcp/tools.ex:request` maps the tool name to its `route` (`"/v1" <> path`) and splits the arguments into query and body. When the tool needs `:code` and only a token is given, `session_code` fills it in by looking the token up. `c3_events` is always forced to `wait=0`, because the watcher script does the waiting, not the tool.
4. `lib/c3_web/mcp/dispatch.ex:run` builds a synthetic `Plug.Conn` and passes it to `C3Web.Router.call`. That conn uses a no-socket `Adapter`, keeps the client IP, sets `private: %{c3_mcp: true}` so the per-IP limit is not counted twice, and adds `Authorization` and `Idempotency-Key` headers. The request goes through `AgentAuth`, the token rate limit, `Idempotency`, the same controller and `lib/c3_web/controllers/v1/fallback_controller.ex`, so MCP and REST cannot drift apart.
5. From the controller on, the chain is identical to the REST chains above. `lib/c3_web/mcp/server.ex:run` turns `{status, body}` into a tool result and rescues exceptions.

Because of step 4, a new REST route is not reachable over MCP until it has an entry in `lib/c3_web/mcp/tools.ex`. See [MCP server](../features/mcp-server/00-INDEX.md).

## Where to go next

| You want | Open |
|---|---|
| Pipelines, plugs and the error shape behind each route | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| Tables, `event_seq` / `next_agent_number` counters, migrations | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| What `AgentAuth` blocks and why the feed skips activity | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| Supervision tree, sweeper, PubSub topics, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `long_poll_max_wait`, `sweeper` and other settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| How status is derived from requests | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Bans, join locks, secret rotation | [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md) |
| Idle close, warnings, purge | [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md) |
| Attachment storage and cleanup | [`../features/attachments/00-INDEX.md`](../features/attachments/00-INDEX.md) |
| The admin's live view of the `admin` topic | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
