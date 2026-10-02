---
doc: features/health-and-home/00-INDEX
repo: c3
kind: feature-index
tier: C
anchored_to: fcd0bd9
generated: 2026-10-02
---
# Health and Home Page

This feature covers two things that are not part of agent coordination. The first is a probe that tells an orchestrator or load balancer whether the service is up and its database is answering. The second is a static landing page for a person who opens the server's root URL in a browser. That page says what C3 is and where agents connect, and it links to the project documentation.

## Does this ticket belong here?

**Yes if it mentions:** the health check, liveness or readiness probe, container restart loops caused by a failing probe, "the database is down but health says ok", the landing page, the front page text, or the documentation link on the front page.
**UI labels:** `C3 — Central Context Coordinator`, `Documentation →`, page title `Central Context Coordinator`, JSON `{"status":"ok"}` / `{"status":"error","db":"unavailable"}`
**Routes:** `GET /healthz`, `GET /`
**No — go elsewhere if:**
- it is about Prometheus metrics or a scrape endpoint → [`metrics`](../metrics/00-INDEX.md)
- it is about a browser page that lists sessions or acts on them → [`admin-ui`](../admin-ui/00-INDEX.md)
- it is about the `/v1` REST API or `/mcp` named on the home page → [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md)

## Entry points

| Route | Page component | Module root |
|---|---|---|
| `GET /healthz` (`:api` pipeline) | `lib/c3_web/controllers/health_controller.ex:show` | `lib/c3_web/controllers/` |
| `GET /` (`:browser` pipeline) | `lib/c3_web/controllers/page_controller.ex:home` → `lib/c3_web/controllers/page_html/home.html.heex` | `lib/c3_web/controllers/` |

## Files

| File | Symbol | Touch this when |
|---|---|---|
| `lib/c3_web/controllers/health_controller.ex` | `C3Web.HealthController.show` | You are changing what counts as healthy. It runs `SELECT 1` through `Ecto.Adapters.SQL.query` against `C3.Repo`. Success returns 200 `%{status: "ok"}`. A DB error returns 503 (`:service_unavailable`) with `db: "unavailable"`. The same endpoint is used for both liveness and readiness, so a DB outage marks the app not-live as well. Change the probe here if a probe must not restart the container when the DB fails. |
| `lib/c3_web/controllers/page_controller.ex` | `C3Web.PageController.home` | You are changing the browser tab title (`:page_title`, `"Central Context Coordinator"`) or adding assigns to the home page. |
| `lib/c3_web/controllers/page_html.ex` | `C3Web.PageHTML` | You are adding another page template. `embed_templates "page_html/*"` picks up any new `.heex` file in that folder automatically. |
| `lib/c3_web/controllers/page_html/home.html.heex` | `Layouts.app`, `id="home"`, `id="home-docs"` | You are changing the landing copy. The text hard-codes the `/v1` and `/mcp` paths and the GitHub README URL. If those routes move, update this file by hand: nothing derives them. The `home` and `home-docs` ids are stable hooks that tests can target. |

## Traps

- `/healthz` runs through the `:api` pipeline, not the agent-auth pipelines, so it requires no token. Keep it unauthenticated, because orchestrators call it without credentials.
- The health check does not report the build version or anything about sessions. It only tells you whether the DB answered. Its response body shows only that the DB was unavailable, never the error's cause.
- The home page is purely static and reads no data. Its text says "There is nothing to see here in a browser". If you add live content, that line becomes wrong, and the [`admin-ui`](../admin-ui/00-INDEX.md) is probably where that content belongs.

## What this feature does NOT own

| Belongs to | Not here |
|---|---|
| [`metrics`](../metrics/00-INDEX.md) | Prometheus text output, the metrics token |
| [`admin-ui`](../admin-ui/00-INDEX.md) | Browser pages under `/admin` |
| [`sessions-and-agents`](../sessions-and-agents/00-INDEX.md) | The `/v1` REST API the home page points to |
| [`mcp-server`](../mcp-server/00-INDEX.md) | The `/mcp` endpoint the home page points to |

## Related

- Features: [`metrics`](../metrics/00-INDEX.md), [`admin-ui`](../admin-ui/00-INDEX.md), [`mcp-server`](../mcp-server/00-INDEX.md)
