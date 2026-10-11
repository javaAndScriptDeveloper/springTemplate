.DEFAULT_GOAL := help
.PHONY: help setup run dev test itest test-scripts build format check lock release-name db-up db-down up down image clean \
	prod-init prod-up prod-down prod-ps prod-logs prod-pull prod-rollback vps-ssh vps-ps vps-logs vps-status vps-psql vps-datagrip rename bricks add remove

# Prefer .env if present, otherwise fall back to the committed example.
ENV_FILE := $(if $(wildcard .env),.env,.env.example)
# Local image tag; CI publishes ghcr.io/<owner>/<repo> instead.
APP_NAME := $(shell basename $(CURDIR))
# Production stack (run these on the VPS). Everything reads deploy/.env.prod, created by `make prod-init`.
PROD := docker compose -f deploy/compose.prod.yml --env-file deploy/.env.prod
# Enabled bricks (bricks/README.md): names from .bricks, comments and blanks dropped. Each enabled brick's Makefile
# is included at the bottom of this file, so its targets show up in `make help`.
BRICKS ?= $(shell sed -e 's/\#.*//' -e '/^[[:space:]]*$$/d' .bricks 2>/dev/null)
# Gradle project under services/ that run/dev/lock/up/image address (SERVICE is the logs filter below).
GRADLE_SERVICE ?= app

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## One-time: install the commit-msg hook that enforces conventional commits
	@git config core.hooksPath .githooks && echo "git hooks: .githooks (commit-msg enforces conventional commits)"

run: setup ## Run the app (auto-starts the compose DB)
	./gradlew :$(GRADLE_SERVICE):bootRun

dev: ## Run with a throwaway Testcontainers DB (no docker-compose needed)
	./gradlew :$(GRADLE_SERVICE):bootTestRun

test: setup ## Run unit tests (no Docker needed)
	./gradlew test

itest: ## Run integration tests (Testcontainers; one Postgres per fork)
	./gradlew integrationTest

lock: ## Refresh services/<service>/gradle.lockfile after changing dependencies
	./gradlew :$(GRADLE_SERVICE):dependencies --write-locks -q

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
	./gradlew :$(GRADLE_SERVICE):bootJar -q
	docker compose --env-file $(ENV_FILE) --profile full up --build -d

down: ## Stop the full stack
	docker compose --profile full down

image: ## Build the jar and the OCI image (tag: $(APP_NAME))
	./gradlew :$(GRADLE_SERVICE):bootJar -q
	docker build -f services/$(GRADLE_SERVICE)/Dockerfile -t $(APP_NAME) .

clean: ## Remove build artifacts
	./gradlew clean

# ------------------------------------------------------------------------------------------------------------ bricks

bricks: ## List bricks and whether each is enabled (.bricks)
	@scripts/brick.sh list

add: ## Enable a brick: make add BRICK=minio
	@test -n "$(BRICK)" || (echo "usage: make add BRICK=<name>   (make bricks lists them)" && exit 1)
	scripts/brick.sh add $(BRICK)

remove: ## Disable a brick and delete what it added: make remove BRICK=minio
	@test -n "$(BRICK)" || (echo "usage: make remove BRICK=<name>" && exit 1)
	scripts/brick.sh remove $(BRICK)

# ------------------------------------------------------------------------------------------- production, from this machine

vps-ssh: ## Shell on the VPS in the app directory (VPS_SSH from .env)
	scripts/vps.sh ssh

vps-ps: ## Production containers and health
	scripts/vps.sh ps

vps-logs: ## Tail production logs (all services; SERVICE=app to narrow)
	scripts/vps.sh logs $(SERVICE)

vps-status: ## Image tag per replica and what /version answers
	scripts/vps.sh deploy-status

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

prod-logs: ## Tail production logs (all services; SERVICE=app to narrow)
	$(PROD) logs -f --tail=200 $(SERVICE)

prod-pull: ## Pull the current APP_IMAGE_TAG now instead of waiting for Watchtower
	$(PROD) pull app
	$(PROD) up -d app

prod-rollback: ## Pin the app to an earlier image: make prod-rollback TAG=1.4.1  (pauses Watchtower)
	@test -n "$(TAG)" || (echo "usage: make prod-rollback TAG=<version|sha-xxxxxxx>" && exit 1)
	$(PROD) stop watchtower
	sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=$(TAG)/' deploy/.env.prod
	$(PROD) up -d --force-recreate app
	@echo "Pinned to $(TAG). Watchtower is stopped; when ready to follow releases again:"
	@echo "  sed -i 's/^APP_IMAGE_TAG=.*/APP_IMAGE_TAG=latest/' deploy/.env.prod && $(PROD) up -d app watchtower"

# Brick make targets (one Makefile per enabled brick; they may use PROD, ENV_FILE and SERVICE).
-include $(foreach b,$(BRICKS),bricks/$(b)/Makefile)
