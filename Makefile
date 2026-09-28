.DEFAULT_GOAL := help
.PHONY: help setup run dev test itest test-scripts build format check lock release-name db-up db-down up down image clean observability-up observability-down

# Prefer .env if present, otherwise fall back to the committed example.
ENV_FILE := $(if $(wildcard .env),.env,.env.example)
# Local image tag; CI publishes ghcr.io/<owner>/<repo> instead.
APP_NAME := $(shell basename $(CURDIR))

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

clean: ## Remove build artifacts
	./gradlew clean
