# --- brick: observability
observability-up: ## Start local Prometheus + Grafana (http://localhost:3000) + Alloy
	docker compose --env-file $(ENV_FILE) --profile observability up -d

observability-down: ## Stop the local observability stack
	docker compose --profile observability down

grafana-push: ## Push bricks/observability/grafana/** to the local Grafana (http://localhost:3000)
	bricks/observability/grafana-push.sh local

grafana-push-cloud: ## Push bricks/observability/grafana/** to Grafana Cloud (GRAFANA_URL + GRAFANA_API_TOKEN from env or .env)
	bricks/observability/grafana-push.sh cloud

grafana-pull: ## Export the dashboard from local Grafana back into bricks/observability/grafana/dashboards
	bricks/observability/grafana-push.sh pull
