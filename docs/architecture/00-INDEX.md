---
doc: architecture/00-INDEX
repo: c3
kind: folder-index
anchored_to: fa64fbd
generated: 2026-10-02
---
# Architecture

The mechanisms that belong to no single feature and turn up in most tickets. A feature document
links here rather than explaining any of this a second time.

## Documents

| File | Answers |
|---|---|
| [`01-request-pipeline-and-routing.md`](01-request-pipeline-and-routing.md) | How an HTTP request enters c3 — endpoint, router pipelines, plugs — and reaches a controller, including the stable error shape |
| [`02-data-model-and-persistence.md`](02-data-model-and-persistence.md) | The SQLite schema — tables, constraints, indexes — the Repo, and the rules for writing a migration |
| [`03-authentication-and-authorization.md`](03-authentication-and-authorization.md) | How an agent, an admin and a metrics scraper are identified, and what each check blocks and returns |
| [`04-processes-and-background-work.md`](04-processes-and-background-work.md) | The supervision tree, the periodic sweeper, PubSub fan-out, ETS tables and telemetry |
| [`05-configuration-and-environments.md`](05-configuration-and-environments.md) | Every C3_* setting, its default, where it is read and validated, and what differs per environment |
| [`06-testing.md`](06-testing.md) | Test suites, their helpers and fixtures, what runs in CI, and why database tests are not async |
| [`07-build-release-and-deploy.md`](07-build-release-and-deploy.md) | Mix project, Makefile targets, the Docker image, compose, release overlays, CI and the release artefact |

## Where this does not go

Anything owned by a product surface lives under [`../features/`](../features/00-INDEX.md).
