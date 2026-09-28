# Observability

Metrics only, pushed. No log shipping, no tracing: `make prod-logs` and Docker's json-file rotation cover a
single-VPS service; add Loki or OTel when you outgrow that.

## Path

```
app  /actuator/prometheus  (management port 8081 in prod, 8080 locally)
 └─► Grafana Alloy  (deploy/alloy/config.alloy, same file everywhere)
      └─► remote_write ─► Grafana Cloud Prometheus       (prod: COMPOSE_PROFILES=observability + GRAFANA_CLOUD_PROM_*)
                       └► local Prometheus :9090         (compose.yml observability profile)
                                └─► Grafana :3000, provisioned from deploy/grafana/
```

- In production Alloy discovers replicas by resolving the compose service name `app` (Docker's DNS returns every
  replica). Locally the app runs on the host, `/etc/hosts` aliases are invisible to DNS discovery, so
  `APP_METRICS_STATIC_TARGET=host.docker.internal:8080` is used instead.
- Every series carries `application` and `env` (`APP_ENV`: `prod` / `local`). The dashboard's *Environment* variable
  and the alert rules (`env="prod"` only) rely on it.
- `app_build_info{version,revision} 1` is the version signal: one series per running build. The dashboard's stat
  panel reads it and `changes(app_build_info[2m]) > 0` draws a marker on every graph at each deploy.

## Dashboard loop

`deploy/grafana/dashboards/app-overview.json` is the source of truth; the local Grafana loads it from disk and Grafana
Cloud receives it from CI. Datasource uid is `grafanacloud-prom` in both places, which is why one file works.

```bash
make observability-up && make run   # http://localhost:3000, anonymous admin
# edit panels in the UI …
make grafana-pull                   # writes the UI state back to the JSON (id/version stripped)
./gradlew test --tests '*DashboardJsonTest'
git commit -am "feat(grafana): add cache hit ratio panel"   # CI pushes to Grafana Cloud on merge
```

`DashboardJsonTest` fails when a query uses a metric the app does not export or a datasource is not the shared uid.
When you add a new meter family, extend `KNOWN_METRICS` in that test.

Ad-hoc pushes: `make grafana-push` (local), `make grafana-push-cloud` (`GRAFANA_URL`, `GRAFANA_API_TOKEN`).

## Alerting

`deploy/grafana/alerting/` holds one rule group (`app-baseline`), a Telegram contact point and the notification
policy. They are pushed (by CI and by `grafana-push.sh`) only when `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are
set; without them dashboards still ship and a notice says alerting was skipped.

| Rule | Fires when | For |
|---|---|---|
| ServiceDown | no `up == 1` for `env="prod"`, or no data at all | 3 m |
| HighErrorRate | 5xx share > 5 % over 10 m with ≥ 20 requests | 5 m |
| DbConnectionsPending | `hikaricp_connections_pending > 0` | 5 m |
| HeapHigh | heap used / max > 90 % | 10 m |

Telegram setup: talk to `@BotFather` → `/newbot` → token; add the bot to a chat and read the chat id from
`https://api.telegram.org/bot<token>/getUpdates`. Service-account token for Grafana Cloud needs
`alert.provisioning:write` in addition to `dashboards:write`.

## Adding a metric

1. Inject `MeterRegistry` and register the meter once (constructor or `@PostConstruct`), name it `app.<area>.<thing>`
   with the unit in the name (`app.orders.created.total`, `app.import.duration.seconds`).
2. Tag with low-cardinality labels only (`outcome`, `type`, a bounded enum). Never user ids, request ids, raw paths.
   Grafana Cloud's free tier caps active series; Micrometer's `uri` tag on HTTP metrics is already the template form.
3. `curl -s localhost:8080/actuator/prometheus | grep app_` to see it.
4. Add the panel, extend `DashboardJsonTest.KNOWN_METRICS` if it is a new prefix, run the test, commit.

Gauges that need a database query (queue depth, row counts) belong in a `@Scheduled` job under `job/` that refreshes
an `AtomicLong`, so a scrape never touches the database.
