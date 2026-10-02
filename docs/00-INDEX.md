---
doc: 00-INDEX
repo: c3
kind: folder-index
anchored_to: fa64fbd
generated: 2026-10-02
origin: generated
---
# c3 — Index

_(This door was generated from the partition. **Replace this paragraph** with the two or three
facts that decide how this codebase is read — the ones no file listing implies. Delete the
`origin: generated` line when you do, and `make sk-ctx-indexes` will stop rewriting it.)_

## Start here

| You have | Open |
|---|---|
| No idea yet how this project works | [`general-context/00-INDEX.md`](general-context/00-INDEX.md) — read it first |
| A ticket, and you need to know what it touches | [`FEATURE-MAP.md`](FEATURE-MAP.md) — routes a ticket by the words it uses |
| A feature you can already name | [`features/00-INDEX.md`](features/00-INDEX.md) |
| A question about something cross-cutting | [`architecture/00-INDEX.md`](architecture/00-INDEX.md) |
| A question about the security model or scaling | [`security.md`](security.md) · [`deploy.md#scaling`](deploy.md#scaling) |

## Documents

| Folder | Contents |
|---|---|
| [`general-context/`](general-context/00-INDEX.md) | The orientation layer: what the project is, how it is laid out, how it runs |
| [`features/`](features/00-INDEX.md) | 11 product surfaces: what each is, how its data flows, which file to touch, what bites |
| [`architecture/`](architecture/00-INDEX.md) | What belongs to no single feature and shows up in most tickets |

## Quick facts

- **Source roots:** `lib`, `plugin`, .ex / .heex / .sh. 82 files, every one owned
  by exactly one document — which is what the coverage gate proves before any of this promotes.
- **Surfaces:** 11 features — 3 at tier A, 6 at tier B, 2 at tier C.
- **Anchored to:** `fa64fbd` — see `_manifest.toml` for the branch, and `history.md`
  for this tree's Known gaps.
