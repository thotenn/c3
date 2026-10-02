---
doc: 00-INDEX
repo: c3
kind: folder-index
anchored_to: fcd0bd9
generated: 2026-10-02
---
# c3 — Index

Three facts decide how c3 is read. **Thread state is derived, not written**: `threads.status` is a
cache that `lib/c3/threads.ex` recomputes from the requests (one request per recipient) inside the
same transaction, and `awaiting` / `processing_by` are never stored. **There is no per-session
process**: writes serialize on a thread row lock and atomic `UPDATE … RETURNING` counters, events
are published to PubSub only after the outermost commit, and one `C3.Sweeper` runs every periodic
job. **There are two doors and one router**: REST under `/v1` and MCP at `/mcp`, where each tool
call is replayed in-process through the same router — so auth, `410`, idempotency and error shapes
are identical by construction. The secret only serves `join`; after that an agent is its token, and
an IP ban never cuts a token.

## Start here

| You have | Open |
|---|---|
| No idea yet how this project works | [`general-context/00-INDEX.md`](general-context/00-INDEX.md) — read it first |
| A ticket, and you need to know what it touches | [`FEATURE-MAP.md`](FEATURE-MAP.md) — routes a ticket by the words it uses |
| A feature you can already name | [`features/00-INDEX.md`](features/00-INDEX.md) |
| A question about something cross-cutting | [`architecture/00-INDEX.md`](architecture/00-INDEX.md) |

## Documents

| Folder | Contents |
|---|---|
| [`general-context/`](general-context/00-INDEX.md) | The orientation layer: what the project is, how it is laid out, how it runs |
| [`features/`](features/00-INDEX.md) | 11 product surfaces: what each is, how its data flows, which file to touch, what bites |
| [`architecture/`](architecture/00-INDEX.md) | What belongs to no single feature and shows up in most tickets |

## Quick facts

- **Source roots:** `lib`, `plugin`, .ex / .heex / .sh. 79 files, every one owned
  by exactly one document — which is what the coverage gate proves before any of this promotes.
- **Surfaces:** 11 features — 3 at tier A, 6 at tier B, 2 at tier C.
- **Anchored to:** `fcd0bd9` — see `_manifest.toml` for the branch, and `history.md`
  for this tree's Known gaps.
