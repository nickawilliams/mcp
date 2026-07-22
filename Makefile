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

default: help

.PHONY: default init fmt validate plan apply ssm logs deploy \
		publish/mail-mcp help vars _print-var

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

# deploy: tell the host to re-pull rendered config/secrets from SSM and
# reconcile compose (services restart only if their config changed). Run after
# `make apply` whenever config changed. Fetches refresh.sh fresh first, so the
# sync logic itself is deployable through the same path.
SSM_CONFIG = /common/mcp/config

## Sync the host with SSM config/secrets and reconcile compose
deploy:
	@cmd_id=$$(aws ssm send-command \
		--targets "Key=InstanceIds,Values=$(INSTANCE)" \
		--document-name "AWS-RunShellScript" \
		--comment "mcp deploy: refresh config from SSM" \
		--parameters 'commands=["aws ssm get-parameter --region us-west-1 --name $(SSM_CONFIG)/refresh.sh --query Parameter.Value --output text > /opt/mcp/refresh.sh","bash /opt/mcp/refresh.sh"]' \
		--query Command.CommandId --output text); \
	echo "deploy: $$cmd_id (waiting...)"; \
	aws ssm wait command-executed --command-id "$$cmd_id" --instance-id "$(INSTANCE)" || true; \
	aws ssm get-command-invocation --command-id "$$cmd_id" --instance-id "$(INSTANCE)" \
		--query "{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}" \
		--output json

# --- Service images ----------------------------------------------------------
# Upstream publishes no linux/arm64 artifact, so we build and publish our own
# image of the pinned upstream tag. Registry auth is ambient (docker login
# locally; docker/login-action in CI).

## Build + push the mail-mcp linux/arm64 image from the pinned upstream tag
publish/mail-mcp:
	@set -euo pipefail; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "Cloning $(MAIL_MCP_REPO) @ $(MAIL_MCP_VERSION)..."; \
	git clone --quiet --depth 1 --branch "$(MAIL_MCP_VERSION)" \
		"$(MAIL_MCP_REPO)" "$$tmp"; \
	docker buildx build --platform linux/arm64 \
		--tag "$(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION)" --push "$$tmp"; \
	echo ""; \
	echo "Published $(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION). Digest for pinning:"; \
	docker buildx imagetools inspect "$(MAIL_MCP_IMAGE):$(MAIL_MCP_VERSION)" \
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
