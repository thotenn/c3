# C3 — Central Context Coordinator. `make` lists every target.

DOCKER  ?= $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null)
COMPOSE ?= $(DOCKER) compose
IMAGE   ?= c3:latest
PORT    ?= 4000
VERSION := $(shell sed -n 's/^ *version: "\(.*\)",/\1/p' mix.exs | head -n 1)

.DEFAULT_GOAL := help

##@ Development

setup: ## Install deps, create and migrate the dev database, fetch asset tools
	mix setup

dev: ## Run the Phoenix server with code reloading (http://localhost:4000)
	iex -S mix phx.server

test: ## Run the test suite
	mix test

precommit: ## Compile with warnings as errors, format, unlock unused deps, test
	mix precommit

fmt: ## Format the code
	mix format

secret: ## Print a fresh SECRET_KEY_BASE
	@mix phx.gen.secret

##@ Plugin (Claude Code)

plugin-validate: ## Validate the marketplace and the c3 plugin with the claude CLI
	claude plugin validate .
	claude plugin validate ./plugin

test-watcher: ## Test /watch and the plugin's scripts, watcher and attach (needs sh + curl)
	mix test test/c3_web/controllers/v1/watch_test.exs test/c3/watch_script_test.exs \
	  test/c3/attach_script_test.exs

##@ Docker

docker-build: ## Build the production image
	$(DOCKER) build -t $(IMAGE) .

docker-up: ## Build and start the stack in the background (needs .env)
	$(COMPOSE) up -d --build

docker-down: ## Stop the stack (keeps the data volume)
	$(COMPOSE) down

docker-logs: ## Follow the container logs
	$(COMPOSE) logs -f

docker-smoke: docker-build ## Build, run a throwaway container and check /healthz
	@bash scripts/docker-smoke.sh "$(DOCKER)" "$(IMAGE)" "$(PORT)"

##@ Release

dist: ## Source tarball of HEAD, c3-<version>.tar.gz (the release asset; needs a clean tree)
	@git diff --quiet HEAD || { echo "uncommitted changes: commit first"; exit 1; }
	git archive --format=tar.gz --prefix=c3-$(VERSION)/ -o c3-$(VERSION).tar.gz HEAD
	@echo "c3-$(VERSION).tar.gz"

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n"} \
	  /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 } \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: setup dev test precommit fmt secret plugin-validate test-watcher docker-build docker-up docker-down docker-logs docker-smoke dist help
