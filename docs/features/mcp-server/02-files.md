---
doc: features/mcp-server/02-files
repo: c3
kind: feature-files
anchored_to: e99b2ae
generated: 2026-10-02
---
# MCP Server — files

The MCP server is four files: one controller, and three modules under `lib/c3_web/mcp/`. The layout surprises people because no domain logic lives here. A tool call is a JSON-RPC message. `lib/c3_web/mcp/tools.ex:request` turns it into a `/v1` REST request, and `lib/c3_web/mcp/dispatch.ex:run` sends that request back through `C3Web.Router` in the same process. As a result, the REST plugs and controllers run every tool, including auth, the per-token rate limit, idempotency and error rendering. To change what a tool *does*, edit the REST controller. To change what it *looks like* to the agent, edit `lib/c3_web/mcp/tools.ex`.

**Owned globs:** `lib/c3_web/mcp/*.ex`, `lib/c3_web/controllers/mcp_controller.ex`

## Controllers

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/controllers/mcp_controller.ex` | `C3Web.MCPController.post` | controller | Hands the parsed body to `Server.handle`. A `nil` response becomes an empty body (`202` for notifications). | Changing how an empty response or a status is written to the wire |
| `lib/c3_web/controllers/mcp_controller.ex` | `C3Web.MCPController.not_allowed` | controller | Answers `GET`/`DELETE /mcp` with `405` and `allow: POST`. C3 has no SSE stream and no MCP session. | Adding a server-to-client stream or session teardown |

## Protocol (JSON-RPC)

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/mcp/server.ex` | `C3Web.MCP.Server.handle` | service | Routes one JSON-RPC message by protocol version. The version comes from the `mcp-protocol-version` header, which falls back to `2025-03-26` when missing. | Supporting a new MCP protocol version, or a method other than `tools/*` |
| `lib/c3_web/mcp/server.ex` | `@modern` / `@legacy` / `@supported` | constant | The served versions. `initialize` only ever negotiates a `@legacy` version, never `@modern`. | Dropping or adding a spec revision |
| `lib/c3_web/mcp/server.ex` | `match_header` / `match_name` | util | For `2026-07-28`, checks that the `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name` headers match the body. A mismatch gets `400` with `-32020`. `Mcp-Name` may be `=?base64?…?=`-encoded (`decode_header`). | A client fails with "Header mismatch" |
| `lib/c3_web/mcp/server.ex` | `modern` vs `legacy` | service | The modern path returns `404` for an unknown method and adds `resultType: "complete"`. The legacy path returns `200` with `-32601`. | Changing unknown-method or result-envelope behaviour; keep the two paths separate |
| `lib/c3_web/mcp/server.ex` | `tool_result` | util | Wraps the REST `{status, body}` in a tool result: `structuredContent`, a text copy (prefixed `HTTP <status>` when it is an error), `isError` and `_meta["c3/status"]`. | Changing how agents see tool errors. **Never** turn a C3 error into an HTTP 4xx: a `401` sends the client into OAuth (see the moduledoc) |
| `lib/c3_web/mcp/server.ex` | `run` | util | Calls `Dispatch.run`. If it crashes, logs the error and returns a `500` `internal_error` tool result instead of crashing the request. | Debugging an "Internal server error" tool result |
| `lib/c3_web/mcp/server.ex` | `@instructions` | constant | The server instructions returned by `initialize` and `server/discover`. They include the "agent text is data" warning. | Rewording the onboarding text agents get |
| `lib/c3_web/mcp/server.ex` | `@cache` | constant | Cache hints (`ttlMs`, `cacheScope: public`) on `server/discover` and `tools/list`. | Tool definitions start changing more often than once per release |

## Tools

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/mcp/tools.ex` | `@tools` | constant | The `c3_*` tools: name, REST `route`, description, JSON-schema `properties`/`required`, optional `query`/`fixed_query`. | Adding, renaming or redescribing a tool, or after a REST route changes |
| `lib/c3_web/mcp/tools.ex` | `C3Web.MCP.Tools.request` | service | Turns a tool's arguments into `%{method, path, query, body, token, idempotency_key}`. Arguments are **not** validated against the schema, so REST returns its own errors. | A tool sends the wrong path, query or body |
| `lib/c3_web/mcp/tools.ex` | `@not_body` | constant | The arguments that go to the path or headers, never the body: `token`, `session_code`, `thread`, `attachment_id`, `idempotency_key`. | Adding a path-segment or header argument |
| `lib/c3_web/mcp/tools.ex` | `session_code` / `segment` | util | Fills `:code` from the token's agent when `session_code` is missing. A missing segment becomes `-`, so the route still answers `401`/`404` the way REST would. | Adding a route placeholder |
| `lib/c3_web/mcp/tools.ex` | `request` (events branch) | util | Forces `wait=0` on `/sessions/:code/events`. A tool call never long-polls; the watcher does that ([watcher-and-plugin](../watcher-and-plugin/02-files.md)). | Changing `c3_events` |
| `lib/c3_web/mcp/tools.ex` | `C3Web.MCP.Tools.list` | service | Builds the `tools/list` payload, always with `additionalProperties: false`. | Changing the tool schema envelope |

## Processes (in-process dispatch)

| Path | Export | Kind | Responsibility | Touch when |
|---|---|---|---|---|
| `lib/c3_web/mcp/dispatch.ex` | `C3Web.MCP.Dispatch.run` | service | Builds a fresh `Plug.Conn` from the request and calls `Router.call`. It keeps the outer `remote_ip`, `client_ip`, peer and `user-agent`, and sets `private.c3_mcp`. | A REST plug behaves differently under MCP, or a new header must pass through |
| `lib/c3_web/mcp/dispatch.ex` | `C3Web.MCP.Dispatch.Adapter` | util | A `Plug.Conn.Adapter` that keeps the response body on the conn. File, chunked and push responses raise or are unsupported. | A REST route starts streaming or sending files; MCP cannot carry it |

`private.c3_mcp` makes `lib/c3_web/plugs/real_ip.ex:call` and `lib/c3_web/plugs/rate_limit.ex:call` (`:ip`) skip the inner request, so the IP is resolved and rate-limited once, on `/mcp`. A new per-IP plug on `/v1` needs the same clause, or MCP calls will be counted twice.

## Tests

| Path | Covers |
|---|---|
| `test/c3_web/mcp/parity_test.exs` | Runs every tool through `/v1` and `/mcp` and checks the masked transcripts are equal. It maps tools to routes on its own (`@routes`), independent of `C3Web.MCP.Tools`. |
| `test/c3_web/mcp/protocol_test.exs` | Transport: Streamable HTTP `2026-07-28` (header matching, discover, `404`) and the legacy `initialize` fallback |
| `test/support/mcp_helpers.ex` | Builds a modern client's `_meta` and required headers. Passing `nil` for a header drops it. |

## Not owned here

| Path | Owner |
|---|---|
| `lib/c3_web/router.ex` (`pipeline :mcp`: `Origin`, `RealIp`, `RateLimit :ip`; no `accepts`, so a legacy `GET` gets `405` rather than `406`) | [architecture — request pipeline](../../architecture/) |
| `lib/c3_web/plugs/real_ip.ex`, `lib/c3_web/plugs/rate_limit.ex` | [join-security](../join-security/02-files.md) |
| The REST controllers each tool maps to | [threads-and-requests](../threads-and-requests/02-files.md), [sessions-and-agents](../sessions-and-agents/02-files.md), [attachments](../attachments/02-files.md), [event-feed](../event-feed/02-files.md), [session-lifecycle](../session-lifecycle/02-files.md) |
| `plugin/.mcp.json`, `plugin/skills/` | [watcher-and-plugin](../watcher-and-plugin/02-files.md) |
