# UWV Reference Data Platform — Makefile
#
# Top-level targets per master agent prompt §5. De zware logica zit in
# scripts/*.sh; deze Makefile orchestreert alleen.
#
# Conventie: alle targets zijn idempotent en herstartbaar.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

CLUSTER_NAME ?= uwv-platform
PLATFORM_CONFIG := platform-config.yaml

# Lees TABLE_FORMAT uit platform-config.yaml (yq). Fallback naar 'delta'.
TABLE_FORMAT ?= $(shell command -v yq >/dev/null 2>&1 && yq -r '.platform.table_format // "delta"' $(PLATFORM_CONFIG) 2>/dev/null || echo delta)

export TABLE_FORMAT
export CLUSTER_NAME

##@ General

.PHONY: help
help: ## Toont deze help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

.PHONY: print-config
print-config: ## Print de actieve platform-configuratie
	@echo "CLUSTER_NAME = $(CLUSTER_NAME)"
	@echo "TABLE_FORMAT = $(TABLE_FORMAT)"
	@echo "Platform config:"
	@cat $(PLATFORM_CONFIG)

##@ Lifecycle

.PHONY: cluster
cluster: ## Maak k3d-cluster aan (idempotent)
	bash scripts/cluster.sh

.PHONY: bootstrap
bootstrap: ## Installeer Helm-charts: cert-manager, MinIO, Postgres, Keycloak, Stackable operators
	bash scripts/bootstrap.sh

.PHONY: deploy-platform
deploy-platform: ## Deploy alle platform-manifests onder platform/
	bash scripts/deploy-platform.sh

.PHONY: seed
seed: ## Genereer en laad synthetische data (10k cliënten)
	bash scripts/seed.sh

.PHONY: test
test: smoke ## Alias voor smoke tests

.PHONY: smoke
smoke: ## Run smoke tests onder tests/smoke/
	bash scripts/run-smoke-tests.sh

.PHONY: e2e
e2e: ## Run e2e test (UC-01 full flow)
	bash tests/e2e/full-flow-uc01.sh

.PHONY: clean
clean: ## Verwijder de k3d-cluster
	bash scripts/clean.sh

##@ Quality

.PHONY: lint
lint: lint-yaml lint-rego lint-python ## Run alle linters

.PHONY: lint-yaml
lint-yaml: ## yamllint over platform/ + infrastructure/
	yamllint -c ci/yamllint.yaml platform/ infrastructure/ || true

.PHONY: lint-rego
lint-rego: ## opa fmt + opa test
	opa fmt --diff opa-policies-src/
	opa test opa-policies-src/

.PHONY: lint-python
lint-python: ## ruff + mypy over data-generation/ en spark-jobs/
	ruff check data-generation/ spark-jobs/
	# mypy is best-effort
	mypy data-generation/ spark-jobs/ --ignore-missing-imports || true

.PHONY: dbt-parse
dbt-parse: ## dbt parse + compile (geen warehouse-toegang vereist)
	cd dbt && dbt deps && dbt parse

##@ Maintenance

.PHONY: doctor
doctor: ## Check vereiste tooling op host
	@bash scripts/doctor.sh

.PHONY: forward
forward: ## Start kubectl port-forwards voor UI's (zie scripts)
	@bash scripts/port-forward.sh
