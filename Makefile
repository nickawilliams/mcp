# Ops wrapper + CI control plane for the MCP platform. Secrets are resolved
# from 1Password at run time via `op run --env-file=.env`; AWS and registry
# credentials come from the ambient environment. Terraform lives under
# ./terraform (see README.md). GitHub Actions workflows are thin wrappers
# over these targets (see AGENTS.md).

SHELL := /usr/bin/env bash

TF := op run --env-file=.env -- terraform -chdir=terraform

# Service images (published to GHCR; consumed by services/*/Dockerfile)
MAIL_MCP_VERSION ?= v0.4.9
MAIL_MCP_IMAGE := ghcr.io/nickawilliams/mail-mcp
MAIL_MCP_REPO := https://github.com/tecnologicachile/mail-mcp.git

# ebay-mcp normally ships prebuilt from npm; these drive publish/ebay-mcp,
# which exists only while the service tracks an unreleased fork branch.
EBAY_MCP_VERSION ?= 1.15.0-browse.2
EBAY_MCP_IMAGE := ghcr.io/nickawilliams/ebay-mcp
EBAY_MCP_REF ?= feat/browse-item-search

default: help

.PHONY: default init fmt validate plan apply ssm logs deploy \
		maintenance/gc maintenance/cimd-pending maintenance/ebay-token \
		publish/mail-mcp publish/ebay-mcp help vars _print-var

# --- Terraform ---------------------------------------------------------------

## Initialize terraform (backend, providers, modules)
init:
	$(TF) init

## Format all terraform files recursively
fmt:
	$(TF) fmt -recursive

## Validate the terraform configuration
validate:
	$(TF) validate

## Show the terraform plan
plan:
	$(TF) plan

## Create/update AWS resources and push rendered config to SSM
apply:
	$(TF) apply

# --- Host ops (SSM Session Manager; no SSH) ----------------------------------
# INSTANCE resolves the host id from terraform output so no id is hard-coded.

INSTANCE = $$($(TF) output -raw host_instance_id)

## Open a shell on the MCP host
ssm:
	aws ssm start-session --target "$(INSTANCE)"

## Tail the compose logs on the MCP host
logs:
	aws ssm start-session --target "$(INSTANCE)" \
		--document-name AWS-StartInteractiveCommand \
		--parameters 'command=["cd /opt/mcp && docker compose logs -f --tail=200"]'

# deploy: advance the host's checkout to origin/main, then re-pull secrets
# from SSM and reconcile compose (services restart only if their config
# changed). Files deploy via git push + this target; `make apply` is only
# needed when AWS resources or secrets changed.

## Sync the host with the pushed repo + SSM secrets and reconcile compose
deploy:
	@if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse origin/main)" ]; then \
		echo "warning: HEAD != origin/main — unpushed work will not deploy" >&2; \
	fi; \
	cmd_id=$$(aws ssm send-command \
		--targets "Key=InstanceIds,Values=$(INSTANCE)" \
		--document-name "AWS-RunShellScript" \
		--comment "mcp deploy: pull repo + refresh secrets" \
		--parameters 'commands=["git -C /opt/mcp fetch origin","git -C /opt/mcp reset --hard origin/main","bash /opt/mcp/scripts/refresh.sh"]' \
		--query Command.CommandId --output text); \
	echo "deploy: $$cmd_id (waiting...)"; \
	aws ssm wait command-executed --command-id "$$cmd_id" --instance-id "$(INSTANCE)" || true; \
	aws ssm get-command-invocation --command-id "$$cmd_id" --instance-id "$(INSTANCE)" \
		--query "{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}" \
		--output json

# --- Maintenance -------------------------------------------------------------
# Auth0 DCR mints a permanent tpc_* app per registration; the free plan caps
# Applications at 10. maintenance/gc clears debris; maintenance/cimd-pending
# surfaces CIMD clients blocked because their metadata URL is not yet in
# terraform. Both use the same least-privilege GC credential (op://-sourced).

## Delete never-authorized Auth0 DCR client debris (GC=--dry-run to preview)
maintenance/gc:
	op run --env-file=.env -- scripts/auth0-gc.sh $(GC)

## Report CIMD metadata URLs blocked by Auth0; add each to terraform cimd_clients
maintenance/cimd-pending:
	op run --env-file=.env -- scripts/auth0-cimd-pending.sh

## Re-mint the eBay user refresh token (browser consent) into 1Password
maintenance/ebay-token:
	op run --env-file=.env -- scripts/ebay-user-token.sh

# --- Service images ----------------------------------------------------------
# Upstream publishes no linux/arm64 artifact, so we build and publish our own
# image of the pinned upstream tag. Registry auth is ambient (docker login
# locally; docker/login-action in CI).

# The sed works around an upstream Dockerfile bug: the crate was renamed
# mail-imap-mcp-rs -> mail-mcp but the COPY source path wasn't updated (the
# upstream Docker workflow has never run, so it goes unnoticed). Only the
# source path is patched — the /mail-imap-mcp-rs destination (and
# ENTRYPOINT) stay as-is. No-ops once fixed upstream.

## Build + push the mail-mcp linux/arm64 image from the pinned upstream tag
publish/mail-mcp:
	@set -euo pipefail; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "Cloning $(MAIL_MCP_REPO) @ $(MAIL_MCP_VERSION)..."; \
	git clone --quiet --depth 1 --branch "$(MAIL_MCP_VERSION)" \
		"$(MAIL_MCP_REPO)" "$$tmp"; \
	sed -i.bak \
		's|/app/target/release/mail-imap-mcp-rs |/app/target/release/mail-mcp |' \
		"$$tmp/Dockerfile" && rm -f "$$tmp/Dockerfile.bak"; \
	docker buildx build --platform linux/arm64 \
		--tag "$(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION)" --push "$$tmp"; \
	echo ""; \
	echo "Published $(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION). Digest for pinning:"; \
	docker buildx imagetools inspect "$(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION)" \
		--format '{{.Manifest.Digest}}'

# ebay-mcp: unlike mail-mcp this is not an upstream-artifact gap — npm ships a
# working arm64-capable package. This target exists only to run an unreleased
# fork branch, whose TypeScript must be compiled somewhere with more headroom
# than the t4g.small host. Retire it (and services/ebay/Dockerfile.build) once
# the branch lands upstream and the service can pin a released npm version.

## Build + push the ebay-mcp linux/arm64 image from the tracked fork branch
publish/ebay-mcp:
	@set -euo pipefail; \
	echo "Building $(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION) from $(EBAY_MCP_REF)..."; \
	docker buildx build --platform linux/arm64 \
		--file services/ebay/Dockerfile.build \
		--build-arg "EBAY_MCP_REF=$(EBAY_MCP_REF)" \
		--tag "$(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION)" --push \
		services/ebay; \
	echo ""; \
	echo "Published $(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION). Digest for pinning:"; \
	docker buildx imagetools inspect "$(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION)" \
		--format '{{.Manifest.Digest}}'

# --- Utils -------------------------------------------------------------------

## This help screen
help:
	@printf "Available targets:\n\n"
	@awk '/^[a-zA-Z\-\_0-9%:\\\/]+/ { \
		helpMessage = match(lastLine, /^## (.*)/); \
		if (helpMessage) { \
			helpCommand = $$1; \
			helpMessage = substr(lastLine, RSTART + 3, RLENGTH); \
			gsub("\\\\", "", helpCommand); \
			gsub(":+$$", "", helpCommand); \
			printf "  \x1b[32;01m%-35s\x1b[0m %s\n", helpCommand, helpMessage; \
		} \
	} \
	{ lastLine = $$0 }' $(MAKEFILE_LIST) | sort -u
	@printf "\n"

## Show the variables used in the Makefile and their values
vars:
	@printf "Variable values:\n\n"
	@awk 'BEGIN { FS = "[:?]?="; } /^[A-Za-z0-9_]+[[:space:]]*[:?]?=/ { \
		if ($$0 ~ /\?=/) operator = "?="; \
		else if ($$0 ~ /:=/) operator = ":="; \
		else operator = "="; \
		print $$1, operator; \
	}' $(MAKEFILE_LIST) | \
	while read var op; do \
		value=$$(make --no-print-directory -f $(MAKEFILE_LIST) _print-var VAR=$$var); \
		printf "  \x1b[32;01m%-35s\x1b[0m%2s \x1b[34;01m%s\x1b[0m\n" "$$var" "$$op" "$$value"; \
	done
	@printf "\n"

_print-var:
	@echo $($(VAR))
