---
doc: features/mcp-server/00-INDEX
repo: c3
kind: feature-index
tier: B
anchored_to: e99b2ae
generated: 2026-10-02
---
# MCP Server

This feature lets an AI agent (for example Claude Code) use C3 as a set of tools without writing any HTTP code. The agent registers C3 as a remote MCP server. It then calls `c3_*` tools to create or join a session, open threads, check its inbox, claim and answer requests, and read attachments. Every tool gives back exactly what the REST API would return for the same action, errors included.

## Does this ticket belong here?

**Yes if it mentions:** an MCP client that cannot connect or that rejects the server; protocol version negotiation; a tool that is missing, badly described or has the wrong arguments; a tool result that looks different from the REST answer; header mismatch errors; an MCP client that starts an OAuth/login flow; the server instructions an agent sees on connecting.
**UI labels:** `c3_create_session`, `c3_join_session`, `c3_session`, `c3_inbox`, `c3_list_threads`, `c3_get_thread`, `c3_open_thread`, `c3_post`, `c3_claim`, `c3_cancel`, `c3_finish`, `c3_reopen`, `c3_events`, `c3_unlock`, `c3_rotate_secret`, `c3_get_attachment`, `c3_leave`, `c3_close_session`; JSON-RPC methods `initialize`, `server/discover`, `tools/list`, `tools/call`, `ping`; headers `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`.
**Routes:** `POST /mcp`, `GET /mcp` (405), `DELETE /mcp` (405)
**No — go elsewhere if:**
- the tool works but the action does the wrong thing (wrong recipient, claim or cancel semantics) → [`threads-and-requests`](../threads-and-requests/00-INDEX.md)
- the agent is not woken up when something arrives → [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md). No MCP tool waits or streams.
- a wrong secret or a ban on join → [`join-security`](../join-security/00-INDEX.md)
- the `c3_events` cursor or event content is wrong → [`event-feed`](../event-feed/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `POST /mcp` | `lib/c3_web/controllers/mcp_controller.ex:post` → `lib/c3_web/mcp/server.ex:handle` | `lib/c3_web/mcp/` |
| `GET /mcp`, `DELETE /mcp` | `lib/c3_web/controllers/mcp_controller.ex:not_allowed` (405, `allow: POST`) | — |

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`threads-and-requests`](../threads-and-requests/00-INDEX.md) | What a tool does. Each tool is one `/v1` route: `lib/c3_web/mcp/tools.ex:request` only builds the request, and `lib/c3_web/mcp/dispatch.ex:run` sends it through the router. |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | Tokens and agent identity. Here the token is only used to find the session code for the path (`lib/c3_web/mcp/tools.ex:session_code`). |
| [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md) | Long-poll, SSE and heartbeat, which are deliberately not tools. `c3_events` always sends `wait=0`. |
| [`attachments`](../attachments/00-INDEX.md) | Attachment storage and limits. `c3_get_attachment` only adds `format=json`. |
| [`join-security`](../join-security/00-INDEX.md) | Per-IP rate limiting and bans. The `:mcp` pipeline in `lib/c3_web/router.ex` counts the per-IP limit once; the dispatched call skips it through `private.c3_mcp`. |

## Notes

- **A C3 error is never an HTTP error on `/mcp`.** A REST `401`/`404`/`422` comes back as HTTP `200` with `isError: true`, the REST body in `structuredContent` and the status in `_meta["c3/status"]` (`lib/c3_web/mcp/server.ex:tool_result`). An HTTP `401` would push the client into OAuth.
- **The two protocol generations behave differently.** For `2026-07-28` the server is stateless: it checks that the headers match the body (`400`, code `-32020`), answers an unknown method with HTTP `404`, and adds `resultType`. For `2025-03-26`…`2025-11-25` it uses `initialize`, but no session is created, and an unknown method is a `200` error. A request without `MCP-Protocol-Version` counts as `2025-03-26` (`lib/c3_web/mcp/server.ex:version`). `initialize` always answers with a legacy version.
- **Arguments are not checked against the schema.** They go to REST unchanged, so a missing token fails as a `401` and a missing title as a `422`. A missing path argument becomes `-` (`lib/c3_web/mcp/tools.ex:segment`).
- **Some arguments are taken out of the body.** `token`, `session_code`, `thread`, `attachment_id` and `idempotency_key` become the path or a header (`lib/c3_web/mcp/tools.ex:@not_body`). If you add a tool with a new path parameter, add it to `@not_body` and to `path/2`.
- **`tools/list` and `server/discover` carry a one-hour public cache hint** (`lib/c3_web/mcp/server.ex:@cache`). A tool change only reaches clients after a new release plus that TTL.
- **A crash during dispatch** is logged and returned as a tool `500` with an `internal_error` body (`lib/c3_web/mcp/server.ex:run`).
- **The router has no `accepts` plug on `:mcp`.** This is on purpose: a legacy `GET` with `Accept: text/event-stream` must get `405`, not `406`.

## Documents

| File | Answers |
|---|---|
| [`01-flows.md`](01-flows.md) | how a JSON-RPC message turns into an in-process `/v1` request and back |
| [`02-files.md`](02-files.md) | which file and which symbol to touch |

## Related

- Architecture: [`01-request-pipeline-and-routing.md`](../../architecture/01-request-pipeline-and-routing.md), [`03-authentication-and-authorization.md`](../../architecture/03-authentication-and-authorization.md)
- Public reference: `c3/docs/mcp.md`
- Features: [`threads-and-requests`](../threads-and-requests/00-INDEX.md), [`watcher-and-plugin`](../watcher-and-plugin/00-INDEX.md), [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md)
