---
doc: features/metrics/00-INDEX
repo: c3
kind: feature-index
tier: C
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Metrics

C3 reports its operating numbers: how many sessions were created and closed, how many joins failed and why, how many IPs were banned, how long watchers waited on the long-poll, and live totals (open sessions, active agents, bans in force, attachment bytes). A Prometheus scraper holding a token reads them as text. The admin pages show the same numbers as a panel.

## Does this ticket belong here?

**Yes if it mentions:** Prometheus, scraping, a counter or gauge that is wrong or missing, a new metric, "since start" numbers resetting, long-poll latency histogram, the metrics token, `/metrics` returning 404/401.
**UI labels:** `C3_METRICS_TOKEN`, `GET /metrics`, `c3_sessions_created_total`, `c3_sessions_closed_total`, `c3_join_failures_total`, `c3_ip_bans_total`, `c3_long_poll_duration_seconds`, `c3_sessions_open`, `c3_agents_active`, `c3_ip_bans_active`, `c3_attachments_bytes`; admin panel "Metrics since the node started".
**Routes:** `GET /metrics`
**No — go elsewhere if:** the admin panel's layout or labels are wrong → [`admin-ui`](../admin-ui/00-INDEX.md); the ban/join-failure *logic* is wrong (not its count) → [`join-security`](../join-security/00-INDEX.md); the long-poll itself misbehaves → [`event-feed`](../event-feed/00-INDEX.md); a liveness probe → [`health-and-home`](../health-and-home/00-INDEX.md). The Phoenix LiveDashboard metrics in `lib/c3_web/telemetry.ex` are the stock Phoenix setup, not this feature.

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /metrics` | `lib/c3_web/controllers/metrics_controller.ex:show` | `lib/c3/metrics.ex` |
| admin panel (no route of its own) | `lib/c3/metrics.ex:snapshot` | `lib/c3/metrics.ex` |

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`session-lifecycle`](../session-lifecycle/00-INDEX.md) | where `[:session, :closed]` is emitted and which `reason` it carries (`lib/c3/sessions.ex`) |
| [`join-security`](../join-security/00-INDEX.md) | emitting `[:join, :failed]` and `[:ip, :banned]` (`lib/c3/security.ex`) |
| [`event-feed`](../event-feed/00-INDEX.md) | the `[:c3, :long_poll, :stop]` span and its `outcome` (`lib/c3/events.ex`) |
| [`admin-ui`](../admin-ui/00-INDEX.md) | rendering the panel (`lib/c3_web/live/admin/sessions_live.ex`) |

## Files

| File | Symbol | Touch it when |
|---|---|---|
| `lib/c3/metrics.ex` | `@events`, `handle_event/4` | adding a counter: list the event in `@events` **and** add a `handle_event/4` clause, or nothing is counted |
| `lib/c3/metrics.ex` | `emit/2` | a domain module needs to emit; it prefixes `:c3`, so callers pass `[:session, :created]`, not `[:c3, …]` |
| `lib/c3/metrics.ex` | `prometheus/0` | a new metric must also be added here; the text output is assembled by hand, there is no reporter library |
| `lib/c3/metrics.ex` | `snapshot/0` | the admin panel needs the new number; it is a separate map from `prometheus/0` |
| `lib/c3/metrics.ex` | `gauges/0`, `attachments_bytes/0` | gauge definitions; they run SQL on every scrape and every admin refresh |
| `lib/c3/metrics.ex` | `@buckets` | changing histogram buckets (seconds); keep them below the long-poll cap `long_poll_max_wait` in `lib/c3/config.ex` |
| `lib/c3_web/controllers/metrics_controller.ex` | `show/2`, `authorized?/2` | auth or response format of `/metrics` |

## Traps

- **Counters are in-memory ETS, reset on every node restart.** No persistence; Prometheus computes rates across resets. A "count went back to zero" ticket is expected behaviour (`lib/c3/metrics.ex:init`).
- **Counting silently no-ops when the table is missing**: `add/2` and `counters/0` rescue `ArgumentError`, so tests that run domain functions without the app don't crash — and a misnamed table would also go unnoticed (`lib/c3/metrics.ex:add`).
- **Labelled counters only appear once incremented.** A `reason` that never occurred has no sample line, and the histogram emits no samples for an outcome with zero polls (`lib/c3/metrics.ex:by`, `lib/c3/metrics.ex:histogram`).
- **Histogram buckets are stored cumulatively at write time** — one event increments every bucket with `seconds <= le`; `+Inf` is the count itself (`lib/c3/metrics.ex:handle_event`).
- **`c3_attachments_bytes` deduplicates**: it groups by `session_id, storage_key` and takes `max(size_bytes)`, so a blob attached several times counts once (`lib/c3/metrics.ex:attachments_bytes`).
- **`c3_agents_active` counts only agents in open sessions** (join on `Session`), not every `:active` row (`lib/c3/metrics.ex:gauges`).
- **No token = 404, not 401.** `C3_METRICS_TOKEN` unset hides the route, like `/admin` without its token; a wrong or missing bearer is a `401` with `www-authenticate` (`lib/c3_web/controllers/metrics_controller.ex:show`). The token must be 32+ characters (`lib/c3/config.ex:metrics_token`).
- Label values are interpolated without escaping (`lib/c3/metrics.ex:sample`); fine for the atom reasons used today, not for free text.

## Related

- Architecture: configuration (`lib/c3/config.ex`), supervision tree (`lib/c3/application.ex` starts `C3.Metrics`)
- Features: [`admin-ui`](../admin-ui/00-INDEX.md), [`event-feed`](../event-feed/00-INDEX.md), [`join-security`](../join-security/00-INDEX.md), [`session-lifecycle`](../session-lifecycle/00-INDEX.md)
