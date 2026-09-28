.DEFAULT_GOAL := help
.PHONY: help setup run dev test itest test-scripts build format check lock release-name db-up db-down up down image clean observability-up observability-down \
	prod-init prod-up prod-down prod-ps prod-logs prod-pull prod-backup-now prod-backup-status prod-backup-list prod-restore prod-rollback grafana-push grafana-push-cloud grafana-pull vps-ssh vps-ps vps-logs vps-status vps-backup-status vps-psql vps-datagrip rename

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

# ------------------------------------------------------------------------------------------- production, from this machine

vps-ssh: ## Shell on the VPS in the app directory (VPS_SSH from .env)
	scripts/vps.sh ssh

vps-ps: ## Production containers and health
	scripts/vps.sh ps

vps-logs: ## Tail production logs (SERVICE=app)
	scripts/vps.sh logs $(SERVICE)

vps-status: ## Image tag per replica and what /version answers
	scripts/vps.sh deploy-status

vps-backup-status: ## Backup freshness on the VPS, checked from this machine
	scripts/vps.sh backup-status

vps-psql: ## psql into the production database through an SSH tunnel (SQL="select 1" for one statement)
	scripts/vps.sh psql $(if $(SQL),"$(SQL)")

vps-datagrip: ## Open the DB tunnel and print a JDBC URL to paste into DataGrip
	scripts/vps.sh datagrip

rename: ## Make the template yours: make rename PKG=com.acme.shop APP=shop
	@test -n "$(PKG)" -a -n "$(APP)" || (echo "usage: make rename PKG=com.acme.shop APP=shop" && exit 1)
	scripts/rename-package.sh $(PKG) $(APP)

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

prod-backup-now: ## Run one off-host backup now (needs rclone set up, docs/deployment.md §6)
	$(PROD) --profile backup run --rm backup once

prod-backup-status: ## Age of the last successful off-host backup; fails if older than BACKUP_MAX_AGE_HOURS
	$(PROD) --profile backup run --rm backup status

prod-backup-list: ## Database dumps on the backup remote, oldest first (stamps for prod-restore)
	$(PROD) --profile backup run --rm backup list

prod-restore: ## Restore the DB from the backup remote: make prod-restore STAMP=<stamp|latest>  (asks; CONFIRM=yes skips)
	@case "$(STAMP)" in \
		latest|[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;; \
		*) echo "usage: make prod-restore STAMP=<stamp|latest>   (stamps: make prod-backup-list)"; exit 1 ;; \
	esac
	@if [ "$(CONFIRM)" != yes ]; then \
		printf 'Overwrite the production database with backup %s? A safety dump is uploaded first. Type yes: ' "$(STAMP)"; \
		read answer || true; \
		[ "$$answer" = yes ] || { echo "aborted"; exit 1; }; \
	fi
	@# Watchtower is stopped only if it was running (a prod-rollback pin keeps it stopped), so it cannot recreate a
	@# replica mid-restore. A failed `ps` or `stop` leaves the stack untouched (ps: nothing to restart; stop: whatever
	@# it tried to stop is started again) and aborts before the restore ever runs. A failed restore still restarts
	@# app (+ watchtower) and the target still fails then.
	@running="$$($(PROD) ps --status running --services)" || { echo "cannot read container state; nothing changed"; exit 1; }; \
		wt="$$(echo "$$running" | grep -x watchtower || true)"; \
		$(PROD) stop app $$wt || { echo "stop failed; nothing was restored"; $(PROD) start app $$wt; exit 1; }; \
		$(PROD) --profile backup run --rm -e RESTORE_CONFIRM=yes backup restore "$(STAMP)"; rc=$$?; \
		$(PROD) start app $$wt; \
		exit $$rc

prod-rollback: ## Pin the app to an earlier image: make prod-rollback TAG=1.4.1  (pauses Watchtower)
	@test -n "$(TAG)" || (echo "usage: make prod-rollback TAG=<version|sha-xxxxxxx>" && exit 1)
	$(PROD) stop watchtower
	sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=$(TAG)/' deploy/.env.prod
	$(PROD) up -d --force-recreate app
	@echo "Pinned to $(TAG). Watchtower is stopped; when ready to follow releases again:"
	@echo "  sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=latest/' deploy/.env.prod && $(PROD) up -d app watchtower"
