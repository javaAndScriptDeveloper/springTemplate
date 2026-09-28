.DEFAULT_GOAL := help
.PHONY: help setup run dev test itest test-scripts build format check lock release-name db-up db-down up down image clean observability-up observability-down \
	prod-init prod-up prod-down prod-ps prod-logs prod-pull prod-backup-now prod-restore prod-rollback grafana-push grafana-push-cloud grafana-pull

# Prefer .env if present, otherwise fall back to the committed example.
ENV_FILE := $(if $(wildcard .env),.env,.env.example)
# Local image tag; CI publishes ghcr.io/<owner>/<repo> instead.
APP_NAME := $(shell basename $(CURDIR))
# Production stack (run these on the VPS). Everything reads deploy/.env.prod, created by `make prod-init`.
PROD := docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## One-time: install the commit-msg hook that enforces conventional commits
	@git config core.hooksPath .githooks && echo "git hooks: .githooks (commit-msg enforces conventional commits)"

run: setup ## Run the app (auto-starts the compose DB)
	./gradlew bootRun

dev: ## Run with a throwaway Testcontainers DB (no docker-compose needed)
	./gradlew bootTestRun

test: setup ## Run unit tests (no Docker needed)
	./gradlew test

itest: ## Run integration tests (Testcontainers; one Postgres per fork)
	./gradlew integrationTest

lock: ## Refresh gradle.lockfile after changing dependencies
	./gradlew dependencies --write-locks -q

release-name: ## Print the version the next push to main would release
	@scripts/next-version.sh

test-scripts: ## Run the bash script tests under scripts/tests
	scripts/tests/run.sh

build: setup ## Full build incl. tests and formatting check
	./gradlew build

format: ## Auto-format the codebase
	./gradlew spotlessApply

check: ## Verify formatting without changing files
	./gradlew spotlessCheck

db-up: ## Start the local Postgres in the background
	docker compose --env-file $(ENV_FILE) up -d db

db-down: ## Stop the local Postgres
	docker compose stop db

up: ## Build the jar + image and run app + db with $(ENV_FILE)
	./gradlew bootJar -q
	docker compose --env-file $(ENV_FILE) --profile full up --build -d

down: ## Stop the full stack
	docker compose --profile full down

image: ## Build the jar and the OCI image (tag: $(APP_NAME))
	./gradlew bootJar -q
	docker build -t $(APP_NAME) .

observability-up: ## Start local Prometheus + Grafana (http://localhost:3000) + Alloy
	docker compose --env-file $(ENV_FILE) --profile observability up -d

observability-down: ## Stop the local observability stack
	docker compose --profile observability down

grafana-push: ## Push deploy/grafana/** to the local Grafana (http://localhost:3000)
	scripts/grafana-push.sh local

grafana-push-cloud: ## Push deploy/grafana/** to Grafana Cloud (GRAFANA_URL + GRAFANA_API_TOKEN from env or .env)
	scripts/grafana-push.sh cloud

grafana-pull: ## Export the dashboard from local Grafana back into deploy/grafana/dashboards
	scripts/grafana-push.sh pull

clean: ## Remove build artifacts
	./gradlew clean

# ---------------------------------------------------------------------------------------------------- production (VPS)

prod-init: ## Create deploy/.env.prod with a generated DB password (asks for confirmation)
	scripts/init-prod-env.sh

prod-up: ## Validate deploy/.env.prod, then start/refresh the production stack and wait for health
	$(PROD) config -q
	$(PROD) up -d --remove-orphans --wait

prod-down: ## Stop the production stack (volumes are kept)
	$(PROD) down

prod-ps: ## Show production containers and their health
	$(PROD) ps

prod-logs: ## Tail production logs (SERVICE=app to narrow)
	$(PROD) logs -f --tail=200 $(SERVICE)

prod-pull: ## Pull the current APP_IMAGE_TAG now instead of waiting for Watchtower
	$(PROD) pull app
	$(PROD) up -d app

prod-backup-now: ## Run one pg_dump immediately (see deploy/backup)
	$(PROD) run --rm backup once

prod-restore: ## Restore a dump: make prod-restore FILE=backups/<stamp>.dump  (stops app replicas first)
	@test -n "$(FILE)" || (echo "usage: make prod-restore FILE=backups/<stamp>.dump" && exit 1)
	$(PROD) stop app
	$(PROD) exec -T db sh -c 'pg_restore --clean --if-exists --no-owner -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"' < $(FILE)
	$(PROD) start app

prod-rollback: ## Pin the app to an earlier image: make prod-rollback TAG=1.4.1  (pauses Watchtower)
	@test -n "$(TAG)" || (echo "usage: make prod-rollback TAG=<version|sha-xxxxxxx>" && exit 1)
	$(PROD) stop watchtower
	sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=$(TAG)/' deploy/.env.prod
	$(PROD) up -d --force-recreate app
	@echo "Pinned to $(TAG). Watchtower is stopped; when ready to follow releases again:"
	@echo "  sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=latest/' deploy/.env.prod && $(PROD) up -d app watchtower"
