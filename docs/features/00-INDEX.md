---
doc: features/00-INDEX
repo: c3
kind: folder-index
anchored_to: e99b2ae
generated: 2026-10-02
---
# Features

One folder per product surface. A feature is not a directory — it is a set of globs that usually
spans several of them: a context module, its schemas, a controller, a plug, a test.

**Every source file has exactly one owner.** A file two features both claim is a partition error,
not a shared file.

## Catalogue

`Depth` is how much detail the folder carries: **full** = flows, files, data and gotchas;
**index only** = this routing card, with the rest not yet written.

| Feature | Tier | Files | Depth |
|---|:--:|--:|---|
| [`sessions-and-agents`](sessions-and-agents/00-INDEX.md) | A | 5 | full |
| [`threads-and-requests`](threads-and-requests/00-INDEX.md) | A | 9 | full |
| [`watcher-and-plugin`](watcher-and-plugin/00-INDEX.md) | A | 3 | full |
| [`admin-ui`](admin-ui/00-INDEX.md) | B | 8 | full |
| [`attachments`](attachments/00-INDEX.md) | B | 3 | full |
| [`event-feed`](event-feed/00-INDEX.md) | B | 4 | full |
| [`join-security`](join-security/00-INDEX.md) | B | 6 | full |
| [`mcp-server`](mcp-server/00-INDEX.md) | B | 4 | full |
| [`session-lifecycle`](session-lifecycle/00-INDEX.md) | B | 1 | full |
| [`health-and-home`](health-and-home/00-INDEX.md) | C | 4 | full |
| [`metrics`](metrics/00-INDEX.md) | C | 2 | full |

## Reading order

Start at the feature's `00-INDEX.md` — it says whether your ticket belongs there and links onward.
Cross-cutting behaviour is in [`../architecture/`](../architecture/00-INDEX.md).
