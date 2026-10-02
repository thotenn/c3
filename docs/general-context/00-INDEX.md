---
doc: general-context/00-INDEX
repo: c3
kind: folder-index
anchored_to: e99b2ae
generated: 2026-10-02
---
# General context

The orientation layer: what `c3` is, how the repository is laid out, how a request or a job
travels through it, and how it is built, tested and released. Read it once before anything else;
after that, [`../FEATURE-MAP.md`](../FEATURE-MAP.md) routes a ticket straight to its feature.

## Documents

| File | Answers |
|---|---|
| [`01-overview.md`](01-overview.md) | What c3 is — a message bus for AI agents on different machines — who calls it, and the ideas that decide how it is read |
| [`02-repo-structure.md`](02-repo-structure.md) | How the repository is laid out — lib/c3 domain contexts, lib/c3_web, plugin/, priv, config, rel, test, docs |
| [`03-lifecycle-and-call-chains.md`](03-lifecycle-and-call-chains.md) | Boot, then the end-to-end chains of create/join, open thread → claim → answer → finish, the long-poll/watch wake-up, and an MCP tool call |
| [`04-build-test-release.md`](04-build-test-release.md) | The everyday commands — setup, dev server, tests, precommit, docker smoke, plugin validation, release |
| [`05-glossary.md`](05-glossary.md) | Domain words — session, code, secret, agent (AGn), label, token, thread (Tn), message (Tn.m), request, response, note, system, any, claim, awaiting, event, seq, cursor, inbox, watch, ban, joins_locked, closing_soon, purge |

## Where this does not go

The detail of any one mechanism is in [`../architecture/`](../architecture/00-INDEX.md), and of any
one product surface in [`../features/`](../features/00-INDEX.md). These documents link down to them
rather than restate them.
