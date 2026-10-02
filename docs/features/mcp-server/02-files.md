---
doc: features/mcp-server/02-files
repo: c3
kind: feature-files
anchored_to: fcd0bd9
generated: 2026-10-02
---
# MCP Server — files

The MCP server is a thin translation layer of four files. It has no business logic of its own. `lib/c3_web/controllers/mcp_controller.ex` receives `POST /mcp`. `lib/c3_web/mcp/server.ex` handles the JSON-RPC protocol and version negotiation. `lib/c3_web/mcp/tools.ex` turns each `c3_*` tool call into a `/v1` REST request. `lib/c3_web/mcp/dispatch.ex` runs that request in-process through `C3Web.Router`. That last step surprises people. A tool call does not call a context function. It goes through the whole REST pipeline again (auth, rate limits, idempotency, controllers, views). So **to change what a tool does, you change the REST route**, and the MCP side follows automatically. A second surprise: C3 errors come back as `isError: true` inside an HTTP `200`, never as an HTTP error status (`lib/c3_web/mcp/server.ex:tool_result`).

**Owned globs:** `lib/c3_web/mcp/*.ex`, `lib/c3_web/controllers/mcp_controller.ex`

## Tool catalogue

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/mcp/tools.ex` | `@tools` | constant | One entry per tool: `name`, `route`, `description`, `properties`, `required`, and optionally `query` / `fixed_query` | adding a tool for a new REST route, changing a tool's description or argument schema |
| `lib/c3_web/mcp/tools.ex` | `@not_body` | constant | Arguments that go into the path or headers, not the body (`token session_code thread attachment_id idempotency_key`) | adding a tool whose route has a new `:param` segment |
| `lib/c3_web/mcp/tools.ex` | `request/2` | util | Builds `%{method, path, query, body, token, idempotency_key}` from the arguments. It does not validate them against the schema, so a bad argument fails the same way it would over REST | changing how arguments map to the query or body. Note: it forces `wait=0` on `/sessions/:code/events` so `c3_events` never long-polls |
| `lib/c3_web/mcp/tools.ex` | `path/2`, `session_code/1`, `segment/1` | util | Fills `:code` / `:thread` / `:attachment`. The session code is looked up from the token through `C3.Sessions.get_agent_by_token`. A missing value becomes `-`, so the route returns REST's own `401`/`404` | a tool on a route with a new path parameter |
| `lib/c3_web/mcp/tools.ex` | `list/0` | util | Produces the `tools/list` definitions, always with `additionalProperties: false` | changing the shape of the input schema |
| `lib/c3_web/mcp/tools.ex` | `@attachments`, `@to`, `@token` | constant | Argument schemas shared by several tools | rewording the help text an agent sees for those arguments |

Some REST endpoints are deliberately not tools: the long-poll wait, the SSE stream and `/heartbeat` (moduledoc of `lib/c3_web/mcp/tools.ex`). Waking an agent up is the watcher's job, not a tool's. See [`watcher-and-plugin`](../watcher-and-plugin/02-files.md).

## Protocol

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/mcp/server.ex` | `handle/2` | service | Classifies a message: a notification or client response gets `202` with no body, `initialize` is answered directly, anything else is routed by version. Batches and non-2.0 messages get `400 -32600` | supporting a new JSON-RPC message kind |
| `lib/c3_web/mcp/server.ex` | `@modern`, `@legacy`, `version/1` | constant | `2026-07-28` is the stateless protocol. `2025-11-25`, `2025-06-18` and `2025-03-26` are legacy. When the `MCP-Protocol-Version` header is missing, the server assumes `2025-03-26` | a new MCP spec revision ships |
| `lib/c3_web/mcp/server.ex` | `modern/4`, `match_header/3`, `match_name/3`, `decode_header/1` | service | `2026-07-28` only: the `MCP-Protocol-Version` / `Mcp-Method` / `Mcp-Name` headers must match the body, or the request gets `400 -32020`. An unknown method gets HTTP `404`. `resultType: "complete"` is added to every result | a header-mirroring rule changes, or Base64 `=?base64?…?=` decoding breaks |
| `lib/c3_web/mcp/server.ex` | `legacy/4`, `initialize/2` | service | Older clients get `initialize` with no session id, and every error comes back in a `200`, including method-not-found | a legacy client fails at handshake |
| `lib/c3_web/mcp/server.ex` | `call/3` | service | Implements `server/discover`, `ping`, `tools/list` and `tools/call`. The other methods return `:method_not_found` | adding an MCP method (resources, prompts) |
| `lib/c3_web/mcp/server.ex` | `@instructions` | constant | The server instructions sent at `initialize`. The same text appears in the `server/discover` result (`lib/c3_web/mcp/server.ex:call`) | changing what an agent is told about using C3 |
| `lib/c3_web/mcp/server.ex` | `@cache` | constant | Caching hints `ttlMs` / `cacheScope: public`, added to `server/discover` and `tools/list` | tool definitions start to vary per caller (then `public` is wrong) |
| `lib/c3_web/mcp/server.ex` | `run/2`, `tool_result/2` | service | Puts the REST `{status, body}` in `structuredContent` and also as text (`HTTP <status> …` on error), sets `_meta["c3/status"]`, and turns a crash into a logged `500 internal_error` tool result | changing how tool errors reach the agent. Never map them to HTTP `401`: that would start an OAuth flow in the client (moduledoc) |

## Controllers and dispatch

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/mcp_controller.ex` | `C3Web.MCPController.post/2` | controller | Sends the `Server.handle` result as JSON, or as an empty body when the response is `nil` | changing the HTTP envelope |
| `lib/c3_web/controllers/mcp_controller.ex` | `C3Web.MCPController.not_allowed/2` | controller | `GET` / `DELETE /mcp` return `405` with `Allow: POST`. There is no SSE stream and no session to delete | ever adding a server-to-client stream |
| `lib/c3_web/mcp/dispatch.ex` | `C3Web.MCP.Dispatch.run/2` | service | Builds a synthetic `Plug.Conn` and calls `C3Web.Router` with it. It keeps the outer `remote_ip` / `client_ip` and sets `private.c3_mcp`, so the per-IP limit and `RealIp` are skipped because they already ran on `/mcp` | a REST plug starts depending on something the synthetic conn lacks (headers, body reader) |
| `lib/c3_web/mcp/dispatch.ex` | `headers/2` | util | Forwards only `authorization` (Bearer token), `idempotency-key`, `user-agent`, and fixed JSON `accept` / `content-type` headers | a REST route starts reading another request header |
| `lib/c3_web/mcp/dispatch.ex` | `C3Web.MCP.Dispatch.Adapter` | util | Fake Plug adapter: `send_resp` captures the body. Chunked responses, `send_file` and upgrades raise or error | a REST route a tool uses starts streaming or sending a file. It will break under MCP (hence `fixed_query: %{"format" => "json"}` on `c3_get_attachment`) |

## Tests

| Path | Covers |
|---|---|
| `test/c3_web/mcp/protocol_test.exs` | Transport: `server/discover`, header mismatch `-32020`, Base64 `Mcp-Name`, unsupported version, `404` for an unknown method, `202` notifications, `400` for batches, `405` for GET/DELETE, no session id, Origin, legacy `initialize`, and REST guards still applying (IP limit counted once, token limit, IP ban, activity, log filtering) |
| `test/c3_web/mcp/parity_test.exs` | Every tool returns what its REST route returns. The route table is written out in the test on purpose, so it does not trust `@tools` |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3_web/router.ex` (`pipeline :mcp`: `Origin`, `RealIp`, `RateLimit :ip`) | [`architecture`](../../architecture/) — request pipeline |
| `lib/c3_web/plugs/real_ip.ex`, `lib/c3_web/plugs/rate_limit.ex` (their `c3_mcp` bypass clauses) | [`architecture`](../../architecture/) — request pipeline |
| `lib/c3_web/plugs/agent_auth.ex`, `lib/c3_web/plugs/idempotency.ex` | [architecture · auth](../../architecture/03-authentication-and-authorization.md), [architecture · request pipeline](../../architecture/01-request-pipeline-and-routing.md) |
| The `/v1` controllers every tool lands on | [`threads-and-requests`](../threads-and-requests/02-files.md), [`sessions-and-agents`](../sessions-and-agents/02-files.md), [`event-feed`](../event-feed/02-files.md), [`attachments`](../attachments/02-files.md), [`session-lifecycle`](../session-lifecycle/02-files.md) |
| `plugin/` (the Claude Code plugin that registers this endpoint) | [`watcher-and-plugin`](../watcher-and-plugin/02-files.md) |
