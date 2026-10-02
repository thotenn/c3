---
doc: general-context/03-lifecycle-and-call-chains
repo: c3
kind: general
anchored_to: fa64fbdfd37e201f327d5422584a528b9e7217b8
generated: 2026-10-02
---
# Lifecycle and call chains

c3 has no process per session. Every write is one SQLite transaction. The context function does three things inside it, in order: it serializes the write (for thread writes, it locks the thread row), it recomputes the cached `threads.status`, and it appends events with the session's next `seq`. Notifying the subscribers is left to the repo: `lib/c3/repo.ex:transaction` wraps only the **outermost** transaction in `lib/c3/events.ex:publish_after`. The events appended inside it are broadcast on PubSub only after that transaction returns `{:ok, _}`. A rollback announces nothing. A long-poll subscribes to the session topic **before** it queries `seq > after`, so an event committed between the query and the wait still wakes it.

## Boot

`lib/c3/application.ex:start` runs these steps in order, under a `:one_for_one` supervisor:

1. `lib/c3/config.ex:validate!` runs first. A bad `C3_*` setting stops the boot before any child starts.
2. `C3Web.Telemetry` starts, then `C3.Repo`.
3. `Ecto.Migrator` runs the migrations at boot only inside a release (`lib/c3/application.ex:skip_migrations?` checks `RELEASE_NAME`). In development, migrations are run by hand. `lib/c3/release.ex:migrate` is the release entry point.
4. `DNSCluster` and `Phoenix.PubSub` (`C3.PubSub`) start. PubSub must be running before anything appends events.
5. The ETS-backed servers start: `C3.Security.BanCache`, `C3.RateLimiter`, `C3.Idempotency`, `C3.Metrics`.
6. `C3.Sweeper` starts only when `C3.Config.get(:sweeper)` is truthy. It is off in test. It expires silent claims through `lib/c3/threads.ex:expire_claims`.
7. `C3Web.Endpoint` starts last, so no request arrives before the steps above are up.

What each child does: [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md).

## Shared mechanics every chain relies on

| Mechanism | Where | The trap |
|---|---|---|
| Event publish after commit | `lib/c3/repo.ex:transaction` → `lib/c3/events.ex:publish_after` | A nested `Repo.transaction` does not publish. Only the outermost one does. An `append!` outside any transaction broadcasts at once (`lib/c3/events.ex:notify`). |
| One broadcast per session per transaction | `lib/c3/events.ex:notify` keeps only the highest `seq` | The message `{:c3_events, session_id, seq}` says *something up to this seq exists*. It does not carry the event. Subscribers re-query. |
| Event seq | `lib/c3/events.ex:append!` does `UPDATE sessions … inc: event_seq` | Must run inside the caller's transaction, so the counter and the event row commit together. |
| Thread lock | `lib/c3/threads.ex:lock_thread!`, an `UPDATE` that bumps `lock_version` | A thread write that skips it can race with a claim or a finish. `release_claims!` locks threads in id order. |
| Derived status | `lib/c3/threads.ex:apply_state!` → `lib/c3/threads/derivation.ex:derive` | Writes `status` and `finished_at` together and appends `thread_status_changed` only when the status moved. Every thread write ends with it. |
| Agent auth | `lib/c3_web/plugs/agent_auth.ex:call` | Runs `touch_seen` always, and `touch_activity` only when `activity: true`. The `:feed` pipeline turns it off: watching does not keep a session alive. |
| Idempotency | `lib/c3_web/plugs/idempotency.ex:call` | `POST` only, after `AgentAuth`. `rotate-secret` goes through `:agent_no_replay` on purpose. |
| Error shape | `lib/c3_web/controllers/v1/fallback_controller.ex:call` | Context functions return `{:error, …}` tuples (often from `Repo.rollback`). The fallback maps them to statuses. |

Routing and plugs: [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md). Auth: [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md).

## Chain 1 — create a session

`POST /v1/sessions` goes through `:v1` only. No token exists yet.

1. `lib/c3_web/router.ex` sends the request through the `:v1` pipeline: `C3Web.Plugs.RealIp`, then `C3Web.Plugs.RateLimit` per IP.
2. `lib/c3_web/controllers/v1/session_controller.ex:create` calls `lib/c3/sessions.ex:create_session`.
3. `create_session` calls `check_ban(ip)` and `validate_agent_label`, then generates the clear secret (`C3.Credentials.generate_secret`).
4. `lib/c3/sessions.ex:insert_session` starts the **transaction**. It inserts the `Session` with a fresh code. On a code collision it rolls back and retries, up to 3 attempts, instead of reusing the failed transaction.
5. `lib/c3/sessions.ex:add_agent!` increments `next_agent_number`, inserts the `Agent` (`AG<n>`) with only the token hash, and appends `:agent_joined` with `lib/c3/events.ex:append!`.
6. The commit happens in `C3.Repo.transaction`, then `lib/c3/events.ex:publish_after` broadcasts. `create_session` then emits `Metrics.emit([:session, :created])`.
7. `lib/c3_web/controllers/v1/session_json.ex:created` renders the response. It is the only place the clear secret and token ever exist.

## Chain 2 — join a session

`POST /v1/sessions/:code/join`.

1. The same `:v1` pipeline runs, then `lib/c3_web/controllers/v1/session_controller.ex:join` calls `lib/c3/sessions.ex:join_session`.
2. `check_ban` runs. A banned IP gets `{:error, :ip_banned, until}` and nothing is recorded.
3. `Credentials.normalize_code` and `get_session_by_code` look up the session. An unknown code goes to `lib/c3/sessions.ex:unknown_code`. It runs a dummy verify (equal timing), records the failure in its own transaction, and may ban the IP.
4. `lib/c3/sessions.ex:join_existing` checks a closed or join-locked session **before** checking the secret, so a locked session never says whether the secret was right.
5. A valid secret starts a **transaction**, `add_agent!` runs as in Chain 1, the transaction commits, and `agent_joined` is published. The watcher of `AG1` turns that event into a `joined` line (`lib/c3/watch.ex`).
6. A wrong secret goes to `lib/c3/sessions.ex:invalid_secret`. In one transaction it records the failure, bans the IP and appends `:security_join_failed`. Enough distinct IPs make it append `:session_joins_locked`.

Details: [`../features/join-security/00-INDEX.md`](../features/join-security/00-INDEX.md), [`../features/sessions-and-agents/00-INDEX.md`](../features/sessions-and-agents/00-INDEX.md).

## Chain 3 — open thread → claim → answer → finish

All four requests go through `:v1` + `:agent` (`AgentAuth`, the per-token `RateLimit`, `Idempotency`). Each controller action first resolves `T3` through `lib/c3/threads/queries.ex:fetch_thread`, which is scoped to the agent's session.

**Open** — `POST /v1/sessions/:code/threads`
1. `lib/c3_web/controllers/v1/thread_controller.ex:create` calls `lib/c3/threads.ex:open_thread`.
2. Before any transaction, `open_thread` runs `check_body_size`, prepares the attachments with `C3.Attachments.prepare` (files are written first and removed by `with_cleanup` on failure), and resolves the targets with `lib/c3/threads/targets.ex`.
3. The **transaction** starts. It inserts the `Thread` (with `next_thread_number!`), calls `insert_requests!` (one request per target) and `Attachments.store!`.
4. It calls `Events.append!(…, :thread_opened)`.
5. `apply_state!(thread, nil, author)` recomputes the status, which normally becomes `pending`, and appends `thread_status_changed`.
6. The transaction commits and the events are published. The recipients' watchers wake up (Chain 4) and print `request` lines.

**Claim** — `POST /v1/threads/:id/claim`
1. `thread_controller.ex:claim` calls `lib/c3/threads.ex:claim`. The **transaction** starts, then `lock_thread!` runs. A finished thread rolls back.
2. A conditional `update_all … where request_state == :open` sets the requests to `claimed`. Of two agents racing for one request, only one matches. If the agent got nothing and holds nothing, `Repo.rollback({:conflict, …, %{claimed_by: …}})` returns a 409.
3. It appends one `:request_claimed` per claimed request, then `apply_state!` runs and the status moves to `processing`.
4. The transaction commits and the events are published.

**Answer** — `POST /v1/threads/:id/messages` with `kind: "response"`
1. `thread_controller.ex:post_message` calls `lib/c3/threads.ex:post_message`. `parse_kind`, the size check, the attachments and `targets_for` all run before the transaction.
2. The **transaction** starts, then `lock_thread!` runs, then `fetch_reply_to!` and `next_message_number!`.
3. `resolvable!` → `insert_message!(:response)` → `resolve!` resolves the request. It claims the request on the way if nobody had. Without `reply_to`, the response resolves every request the author may answer.
4. The transaction updates `last_message_at` and appends `:message_posted` with `resolved` / `resolved_for`. The requester's watcher keys its `answer` line on `resolved_for`.
5. `apply_state!` runs, the status becomes `answered`, the transaction commits and the events are published.

**Finish** — `POST /v1/threads/:id/finish`
1. `thread_controller.ex:finish` calls `lib/c3/threads.ex:finish`, which calls `finish_thread`. The **transaction** starts, then `lock_thread!` and `check_opened_by!` run. Only the thread's opener can finish it. The admin uses `admin_finish`, which is always forced.
2. Finishing an already finished thread is a no-op (`changed: false`).
3. Pending requests without `force` make it roll back with a 409 that lists them. With `force`, they are set to `cancelled` and each gets a `:request_cancelled` event.
4. `apply_state!(thread, now, …)` sets `finished_at`, the status becomes `finished`, the transaction commits and the events are published.

`reopen` follows the same pattern: `lock_thread!` → `apply_state!(thread, nil, …)`. Status rules: [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md). Tables and constraints: [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md).

## Chain 4 — the long-poll / watch wake-up

`GET /v1/sessions/:code/watch?after=N&wait=S` goes through `[:sse, :feed]`. `AgentAuth` runs with `activity: false`.

1. `plugin/skills/c3/scripts/c3-watch.sh` `wait` loops on `curl …/watch?after=$after&wait=…`. It saves the cursor after every poll, so a restart loses nothing.
2. `lib/c3_web/controllers/v1/event_controller.ex:watch` caps `wait` at `long_poll_max_wait` and calls `watch_after`.
3. `lib/c3/events.ex:wait_after` calls **`subscribe(session)` first**. Only then does it run `list_after(session, after_seq)`. Its `:subscribed` option exists so tests can commit an event in exactly that gap.
4. If events already exist, the outcome is `immediate`. If not, `await` blocks in `receive`. It ignores `{:c3_events, id, seq}` messages with `seq <= after`, and re-queries on any newer one (`woken`). When the deadline passes it returns `[]` (`timeout`).
5. A writer's outermost commit leads to `lib/c3/events.ex:broadcast` on `"session:<id>"`, which is the message that wakes step 4.
6. `watch_after` maps the events through `lib/c3/watch.ex:line`. If none of them concern this agent and time remains, it polls again with the advanced cursor.
7. The response is `text/plain`: a `cursor <seq>` line, then the lines that concern this agent. The `after` clause of `wait_after` unsubscribes and flushes the leftover messages from the mailbox.

`GET /v1/sessions/:code/events?wait=S` (`event_controller.ex:index`) runs the same `wait_after` and returns JSON. `event_controller.ex:stream` (SSE) also subscribes before `list_after`. Details: [`../features/event-feed/00-INDEX.md`](../features/event-feed/00-INDEX.md), [`../features/watcher-and-plugin/00-INDEX.md`](../features/watcher-and-plugin/00-INDEX.md).

## Chain 5 — an MCP tool call

`plugin/.mcp.json` points the client at `<server_url>/mcp`. Every MCP tool call becomes an in-process `/v1` request.

1. `lib/c3_web/router.ex` sends the request through the `:mcp` pipeline: `C3Web.Plugs.Origin`, `RealIp`, then `RateLimit` per IP. There is no `accepts`, so a `GET` gets a 405 from `lib/c3_web/controllers/mcp_controller.ex:not_allowed` instead of a 406.
2. `lib/c3_web/controllers/mcp_controller.ex:post` calls `lib/c3_web/mcp/server.ex:handle`. A notification gets 202. `initialize` serves legacy clients. Otherwise `handle` picks the protocol version from the `MCP-Protocol-Version` header: `modern` checks the headers against the body, `legacy` does not.
3. `call(conn, "tools/call", …)` calls `lib/c3_web/mcp/tools.ex:request`, which maps the tool to `{method, path, query, body, token, idempotency_key}`. The arguments are not validated against the schema here, so REST fails them exactly as it would a direct call. A tool that needs `:code` but gets only a token looks the code up through `Sessions.get_agent_by_token`. An unknown token becomes the path `-`, which REST answers with a 401. `c3_events` is forced to `wait=0`.
4. `lib/c3_web/mcp/dispatch.ex:run` builds a fresh `Plug.Conn` with a stub adapter and the headers `authorization: Bearer …` and `idempotency-key`. It reuses the outer `client_ip` and marks the conn with `private.c3_mcp`. Then it calls `C3Web.Router.call` **again**.
5. The inner request runs Chain 1–4 unchanged: the same pipelines, auth, idempotency, transactions and publish-after-commit.
6. `lib/c3_web/mcp/server.ex:tool_result` wraps the REST status and body. A status of 400 or more becomes `isError: true` inside an HTTP 200, never an HTTP 401, which would push the client into OAuth. A crash in the inner request is rescued in `server.ex:run` and turned into a 500 tool result.

Details: [`../features/mcp-server/00-INDEX.md`](../features/mcp-server/00-INDEX.md).

## Where to go next

| You want | Open |
|---|---|
| Why a request got 401/403/410, and what each plug does | [`../architecture/01-request-pipeline-and-routing.md`](../architecture/01-request-pipeline-and-routing.md) |
| The tables behind `seq`, `lock_version` and `request_state` | [`../architecture/02-data-model-and-persistence.md`](../architecture/02-data-model-and-persistence.md) |
| Token, admin and metrics identity | [`../architecture/03-authentication-and-authorization.md`](../architecture/03-authentication-and-authorization.md) |
| The supervision tree, the Sweeper, PubSub topics, ETS | [`../architecture/04-processes-and-background-work.md`](../architecture/04-processes-and-background-work.md) |
| `long_poll_max_wait`, `claim_ttl`, `sweeper` and the other settings | [`../architecture/05-configuration-and-environments.md`](../architecture/05-configuration-and-environments.md) |
| Testing the subscribe/query gap and why DB tests are not async | [`../architecture/06-testing.md`](../architecture/06-testing.md) |
| When migrations run in a release | [`../architecture/07-build-release-and-deploy.md`](../architecture/07-build-release-and-deploy.md) |
| Thread status derivation, cancel and reopen | [`../features/threads-and-requests/00-INDEX.md`](../features/threads-and-requests/00-INDEX.md) |
| Leave, close, idle expiry | [`../features/session-lifecycle/00-INDEX.md`](../features/session-lifecycle/00-INDEX.md) |
| Attachments stored inside the open/post transaction | [`../features/attachments/00-INDEX.md`](../features/attachments/00-INDEX.md) |
| The admin pages that subscribe to the `admin` topic | [`../features/admin-ui/00-INDEX.md`](../features/admin-ui/00-INDEX.md) |
| The `long_poll` telemetry outcomes | [`../features/metrics/00-INDEX.md`](../features/metrics/00-INDEX.md) |
