---
doc: FEATURE-MAP
repo: c3
kind: folder-index
anchored_to: e99b2ae
generated: 2026-10-02
---
# Feature map — route a ticket by what it calls things

A ticket says *"the watcher stops getting events after a reconnect"*. It does not name a module
and it does not name a route. **This table is the translation**, and it is the first thing to read
when a ticket arrives.

Find the words the ticket uses in the middle column, open that feature's index, and let its
*"Does this ticket belong here?"* block confirm or send you elsewhere. Two features claiming the
same words is normal — the *"No — go elsewhere if"* block in each one is what separates them.

**Generated from the features' own indexes.** Nothing here is maintained by hand, so it cannot
drift from the documents it points at; a feature that reads `_(not documented yet)_` carries a
routing card only.

| Feature | Tier | What a ticket calls it | Routes |
|---|:--:|---|---|
| [`admin-ui`](features/admin-ui/00-INDEX.md) | B | confirmations such as, env var | `/admin` |
| [`attachments`](features/attachments/00-INDEX.md) | B | (field on open/post), error | `/v1/attachments/:id` |
| [`event-feed`](features/event-feed/00-INDEX.md) | B | query params, header, response fields, line, comment, event types such as, (full list ) | `/v1/sessions/:code/events`, `/v1/sessions/:code/events/stream` |
| [`health-and-home`](features/health-and-home/00-INDEX.md) | C | page title, JSON | `/healthz`, `/` |
| [`join-security`](features/join-security/00-INDEX.md) | B | banned IP, "banned until midnight", wrong secret / wrong security number, unknown session code, brute force, ban length or escalation, allowlist, unbanning an address, IPv6 users banned together (same /64), ban lasting the wrong time around DST or timezone, failed join history being purged, ban still in effect after a restart | — |
| [`mcp-server`](features/mcp-server/00-INDEX.md) | B | JSON-RPC methods, headers | `/mcp` |
| [`metrics`](features/metrics/00-INDEX.md) | C | admin panel "Metrics since the node started" | `/metrics` |
| [`session-lifecycle`](features/session-lifecycle/00-INDEX.md) | B | (event type), values /, config keys, the admin's purge action | — |
| [`sessions-and-agents`](features/sessions-and-agents/00-INDEX.md) | A | tools | `/v1/sessions`, `/v1/sessions/:code` |
| [`threads-and-requests`](features/threads-and-requests/00-INDEX.md) | A | (tool names defined ); fields,, statuses | `/v1/sessions/:code/threads`, `/v1/sessions/:code/inbox` |
| [`watcher-and-plugin`](features/watcher-and-plugin/00-INDEX.md) | A | Line kinds:,. Line form: | `/v1/sessions/:code/watch` |

## When nothing matches

The ticket is probably cross-cutting: the mechanisms that belong to no single surface. Those live
in [`architecture/`](architecture/00-INDEX.md). A question about how the whole fits together starts in
[`general-context/`](general-context/00-INDEX.md).

If it matches nothing in any of the three, the partition has a gap — that is a finding, not a
dead end. Record it rather than filing the work under the closest feature.
