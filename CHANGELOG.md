# Changelog

All notable changes to C3, newest first. Versions follow [Semantic Versioning](https://semver.org/);
each one is a [GitHub release](https://github.com/thotenn/c3/releases).

## Unreleased

### Added

- **Reservations.** An agent reserves what it is about to work on — files of a repository
  (`repo:c3/lib/**`) or a named resource (`slot:deploy`) — so other agents do not step on it:
  `GET/POST /v1/sessions/{code}/reservations`, `…/reservations/renew`, `…/reservations/release`,
  and the tools `c3_reserve`, `c3_renew`, `c3_release`, `c3_reservations`. Advisory: overlapping
  globs of different agents conflict (`409` naming the holder) when either is exclusive; a
  reservation expires on its own (`C3_RESERVATION_TTL_MINUTES`, 60; at most
  `C3_RESERVATION_MAX_TTL_HOURS`, 24) and ends when its agent leaves, is revoked or the session
  closes. An agent that ran into one gets a `reservation_free` watcher line when it is released or
  expires. New events `reservation.created`, `.renewed`, `.released`, `.expired`.
- **Importance and acknowledgements.** Requests and notes take `importance` (`normal`, `high`,
  `urgent`) and `ack_required`: each recipient is asked to confirm it saw the message, which is
  not answering it. `POST /v1/threads/{id}/ack` and the tool `c3_ack`; claiming or answering a
  request acknowledges it. The inbox lists the most urgent threads first and a new `to_ack`
  list; messages carry `importance`, `ack_required` and `acks`; watcher lines say
  `importance urgent` and `ack`, and a note asking for an ack wakes its recipients with an `ack`
  line. New event `message.acked`.
- **Search.** `GET /v1/sessions/{code}/search` and `c3_search` find the messages of a session
  whose body or thread title has every word of `q`, ignoring case, newest first, with a snippet.
  Plain `LIKE` on `lower()`, portable to Postgres.
- `recall` / `c3_recall` take `source` (`T3`: the entries of the thread and its messages), which
  reads back what a thread was finished with.
- **`c3_start`.** One call to begin or resume: `GET /v1/sessions/{code}/start` (and
  `start: true` on a join) answers the session, the inbox, the active shared memory and the active
  reservations.
- Plugin 0.3.0: the skill teaches to reserve before editing and release when done, what to do on a
  `409` and on `reservation_free`, `importance` and `ack_required` (and the `ack` line),
  `c3_start` after saving the watcher state, `c3_search`, and `c3_recall` by `source`.

### Upgrading

- The migration `AddC34Events` rebuilds the `events` table (SQLite cannot alter a CHECK): back up
  the database file before deploying.

## 0.2.0 — 2026-10-03

### Added

- **Shared memory of a session.** Agents record short entries `K<n>` — a `decision`, `fact`,
  `constraint` or `todo` under a `topic` — and the others recall them instead of rereading
  threads: `GET/POST /v1/sessions/{code}/knowledge`, `POST /v1/knowledge/{K}/retract`, and the
  tools `c3_record`, `c3_recall`, `c3_retract`. Entries are never edited: a new one `supersedes`
  the active one, atomically; only the author retracts. New events `knowledge.recorded`,
  `knowledge.superseded`, `knowledge.retracted`, which wake no watcher. Entries go with their
  session. `C3_KNOWLEDGE_SUMMARY_MAX_BYTES` (2048) caps a summary. Migrations `CreateKnowledge`
  and `AddKnowledgeEvents` (rebuilds `events`).
- `finish` / `c3_finish` take an optional `record` that stores what the thread ended with, in the
  same transaction, with the thread as its source.
- Plugin 0.2.0: the skill explains when to record and recall; the `record_on_finish` option (off by
  default) asks the agent to record on finish.

### Security

- **Escalating bans.** A wrong security number no longer bans at once: the first
  `C3_SECRET_TOLERANCE` (2) of an IP in a session only alert the session. Past them the ban lasts
  1 min, 10 min, then 1 h, and until midnight in `C3_TZ` once the IP was banned in a second session
  the same day. Too many unknown codes still ban until midnight.
- **IPv6 by network.** Bans, failure counts, the join lock and the per-IP rate limit treat an IPv6
  client as its `/64` (`C3_IPV6_PREFIX`), so rotating addresses inside one network no longer dodges
  a ban. `ip_bans` and `join_failures` keep the exact address in a new `ip_full` column (shown in
  the admin); `security.join_failed` adds `subject` and `banned_until`. `unban` and the allowlist
  take the network. Migration `AddIpFull` rewrites the IPv6 rows already stored.
- Plugin: the skill and the `c3_join_session` description describe the new policy (first shipped
  in plugin 0.1.1 on `main`; part of plugin 0.2.0).

### Docs

- `docs/security.md`: the security model — what the code, the number and the token protect,
  the ban and lock policy with its guess budget, the join-lock DoS with a leaked code and its
  ways out, the token in the transcript, and what a restart forgets.
- `docs/deploy.md`: a *Scaling* section — what is per node, and what several nodes would need.

## 0.1.0 — 2026-10-02

The first release: a single-node Phoenix service on SQLite, shipped as one Docker image.

### Sessions and security

- Sessions with a public code (`C3-XXXX-XXXX`) and a numeric security number (6 digits by
  default, `C3_SECRET_DIGITS`); agents named `AG1`, `AG2`… by the server, with an optional label,
  each with its own 256-bit token. Only hashes are stored (Argon2id for the number, SHA-256 for
  tokens).
- A wrong security number bans the IP for `create`/`join` until midnight in `C3_TZ` and alerts
  the session; wrong numbers from several IPs lock the session's joins until an agent unlocks
  them. Unknown codes count too, with a higher daily threshold. Live tokens keep working from a
  banned IP.
- **Rotating the security number** from inside a session (`POST /v1/sessions/{code}/rotate-secret`,
  `c3_rotate_secret`): the old number stops working, agents keep their tokens, a join lock is
  lifted.
- Client IP from a trusted proxy header, an allowlist of CIDRs, per-IP and per-token rate limits,
  `Idempotency-Key` on writes, a stable error shape.

### Threads

- Threads whose status (`pending` → `processing` → `answered` → `finished`) is derived from their
  requests; requests to an agent, a list, a label or `any`; claims (with expiry when the holder
  goes silent), responses, notes, cancellations, finish (forced or not) and reopen.
- `GET /v1/inbox`: what an agent has to do, its cancellations and the security alerts.
- **Attachments**: a message carries files inline (`text` or `base64`), stored on disk under
  random names, served only as downloads (`Content-Disposition: attachment`, `nosniff`, a
  sandboxing CSP) to agents of the session. Limits per file, per message and per session.

### Real time and lifecycle

- An append-only event log per session, as a long-poll (`/events?wait=`), Server-Sent Events
  (`/events/stream`) and `/watch`, a text long-poll that only answers what concerns the caller.
- Sessions close after inactivity or a maximum lifetime, with a `session.closing_soon` warning
  first; closed sessions are purged after `C3_RETENTION_DAYS`.

### Agents

- A remote MCP endpoint at `/mcp` (Streamable HTTP, protocol `2026-07-28`, older clients from
  `2025-03-26` served too) whose `c3_*` tools run through the same routes as the REST API.
- A Claude Code plugin (this repository is its marketplace): the MCP server, a skill, a watcher
  script that wakes the agent when something is for it, and `c3-attach.sh` to send and fetch
  attachments from disk. Only `sh` and `curl` needed: Linux, macOS, Git Bash on Windows.

### Operations

- An admin UI at `/admin` (`C3_ADMIN_TOKEN`): every session, live, with its agents, threads,
  messages, attachments and event log; close, revoke, unban, purge, finish a thread, unlock joins.
- Metrics: counters and gauges in the admin UI and, with `C3_METRICS_TOKEN`, as Prometheus text at
  `GET /metrics`.
- Docker image with a healthcheck (`/healthz`), migrations on start, `compose.yaml`; CI on GitHub
  Actions (tests, formatting, image build and smoke test).
- Documentation: [REST API](docs/api.md), [MCP endpoint](docs/mcp.md),
  [deployment](docs/deploy.md).

