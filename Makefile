.DEFAULT_GOAL := help
.PHONY: help setup run dev test itest test-scripts build format check lock release-name db-up db-down up down image clean

# Prefer .env if present, otherwise fall back to the committed example.
ENV_FILE := $(if $(wildcard .env),.env,.env.example)

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
	docker compose down

up: ## Build & run the full stack (app + db) with $(ENV_FILE)
	docker compose --env-file $(ENV_FILE) --profile full up --build -d

down: ## Stop the full stack
	docker compose --profile full down

image: ## Build the OCI image (tag: spring-template)
	docker build -t spring-template .

clean: ## Remove build artifacts
	./gradlew clean
