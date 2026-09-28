---
name: grafana
description: Edit, push or pull the Grafana dashboard and alert rules under deploy/grafana. Use when the user wants a new panel, a changed alert, dashboards pushed to Grafana Cloud or local Grafana, or asks why a metric is missing from the dashboard.
---

# Dashboards and alerting

`deploy/grafana/dashboards/app-overview.json` is the single source of truth; the same file renders locally and in
Grafana Cloud because both datasources use uid `grafanacloud-prom`. Alert rules, the Telegram contact point and the
notification policy live in `deploy/grafana/alerting/`.

## Loop for a dashboard change

1. `make observability-up` then `make run` — Grafana at http://localhost:3000 loads the JSON from disk.
2. Edit in the UI (or edit the JSON directly for small changes).
3. `make grafana-pull` writes the UI state back to the JSON (strips `id`/`version`).
4. `./gradlew test --tests '*DashboardJsonTest'` — every `expr` must use a metric the app exports and every
   datasource must be the shared uid. Extend the known-metric list in the test when you add a new meter.
5. Commit under `deploy/grafana/**`. The `dashboards` workflow pushes to Grafana Cloud on merge (needs the
   `GRAFANA_URL` and `GRAFANA_API_TOKEN` repository secrets).

Ad-hoc push without CI: `make grafana-push` (local) or `make grafana-push-cloud` (`GRAFANA_URL`,
`GRAFANA_API_TOKEN` from env or `.env`).

## Alerting

Pushed only when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are set (CI secrets or local env). Rules are one
rule group (`app-baseline`) replaced atomically. Rules query `env="prod"` only; local runs never alert.

## Adding a metric

1. Register it with Micrometer (constructor-injected `MeterRegistry`; name `app.<area>.<thing>`, units in the name).
2. Verify at `curl localhost:8080/actuator/prometheus | grep app_`.
3. Add the panel, add the metric prefix to `DashboardJsonTest.KNOWN_METRICS`, run the test, commit.

Mind cardinality: Grafana Cloud's free tier caps active series. Never tag with user ids, request ids or raw paths.
