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
EBAY_MCP_VERSION ?= 1.15.0-browse.5
# The image keeps the plain name while the source repo carries the fork-
# prefix: they are different namespaces. The GHCR package is not linked to a
# repo, so renaming the fork does not touch it, and the host pins this image by
# digest — renaming the package would mean a rebuild and redeploy for nothing.
EBAY_MCP_IMAGE := ghcr.io/nickawilliams/ebay-mcp
EBAY_MCP_REPO := https://github.com/nickawilliams/fork-ebay-mcp.git
EBAY_MCP_REF ?= feat/browse-item-search

default: help

.PHONY: default init fmt validate plan apply ssm logs deploy \
		maintenance/ebay-token \
		publish/mail-mcp publish/ebay-mcp icons help vars _print-var

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
#
# MCP_PREFIX is passed from terraform output rather than left to the fallback
# literal in refresh.sh, so the path the host reads and the path terraform
# wrote can never disagree — including across a change of partition, where
# they otherwise would for exactly as long as the two were out of step.

## Sync the host with the pushed repo + SSM secrets and reconcile compose
deploy:
	@if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse origin/main)" ]; then \
		echo "warning: HEAD != origin/main — unpushed work will not deploy" >&2; \
	fi; \
	prefix=$$($(TF) output -raw path_prefix); \
	cmd_id=$$(aws ssm send-command \
		--targets "Key=InstanceIds,Values=$(INSTANCE)" \
		--document-name "AWS-RunShellScript" \
		--comment "mcp deploy: pull repo + refresh secrets" \
		--parameters "commands=[\"git -C /opt/mcp fetch origin\",\"git -C /opt/mcp reset --hard origin/main\",\"MCP_PREFIX=$$prefix bash /opt/mcp/scripts/refresh.sh\"]" \
		--query Command.CommandId --output text); \
	echo "deploy: $$cmd_id (waiting...)"; \
	aws ssm wait command-executed --command-id "$$cmd_id" --instance-id "$(INSTANCE)" || true; \
	aws ssm get-command-invocation --command-id "$$cmd_id" --instance-id "$(INSTANCE)" \
		--query "{Status:Status,Stdout:StandardOutputContent,Stderr:StandardErrorContent}" \
		--output json

# --- Maintenance -------------------------------------------------------------
# The Auth0 tenant sweeps that used to live here (maintenance/gc,
# maintenance/cimd-pending) moved to ~/Projects/infrastructure on 2026-08-27,
# with the credential they share: both act on the tenant, which that repo owns.
# What remains is this stack's own upstream credential.

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
	rev=$$(git ls-remote "$(EBAY_MCP_REPO)" "refs/heads/$(EBAY_MCP_REF)" | cut -f1); \
	if [ -z "$$rev" ]; then echo "no such branch: $(EBAY_MCP_REF)" >&2; exit 1; fi; \
	echo "Building $(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION) from $(EBAY_MCP_REF) @ $$rev..."; \
	docker buildx build --platform linux/arm64 \
		--file services/ebay/Dockerfile.build \
		--build-arg "EBAY_MCP_REF=$(EBAY_MCP_REF)" \
		--build-arg "EBAY_MCP_REV=$$rev" \
		--tag "$(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION)" --push \
		services/ebay; \
	echo ""; \
	echo "Published $(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION). Digest for pinning:"; \
	docker buildx imagetools inspect "$(EBAY_MCP_IMAGE):$(EBAY_MCP_VERSION)" \
		--format '{{.Manifest.Digest}}'

# --- Service icons -----------------------------------------------------------
# Brand glyph in (services/<service>/logo.svg, alongside the rest of that
# service's payload), MCP-themed favicon set out (caddy/icons/<service>/). The
# generated files are committed: the host runs no toolchain, it only serves
# what git delivered, so regenerating is a local step whose output lands in a
# normal commit. The service list is the set of services that have a logo, so
# +1 service = +1 logo.svg and nothing here to edit; a service without one is
# skipped rather than failing the run.
#
# A glyph is the mark alone — no wordmark, no background plate, no padding.
# The generator strips fill/stroke/class/style/color so the mark inherits the
# tile's ink, keeps genuine fill="none" holes, and re-points strokes at
# currentColor; it drops <image>, <style> and <script>, so a mark whose shape
# depends on a CSS class comes out empty.
#
# Paint each glyph in its brand colour and keep it to ONE hex. That colour is
# never drawn — it is stripped with everything else — but it is what the tile
# gradient is derived from, so it belongs beside the art rather than in a map
# here. Sniffing picks the most-repeated hex rather than the most prominent
# one, which is why a single fill matters: a multi-colour source picks by
# accident. It also skips greys, near-black and near-white (chroma < 0.045, or
# lightness outside 0.12-0.95), so a colourless glyph fails the run outright
# with "No brand colour found".
#
# If a brand ever genuinely needs two colours, the tile gradient already has
# two stops — teaching the generator `--color '#a,#b'` is the cheap path, and a
# better home for the second colour than a mark that is a smudge at 16px.
#
# The generator runs in a throwaway image (tools/icon/) because it needs Node,
# a rasteriser and two PNG optimisers that nothing else here wants; docker is
# already required by the publish/* targets, so this adds no new dependency.
#
# The PNGs are quantised to a 24-colour palette and re-deflated, which is a
# ~90% saving and keeps every 512 tile under 10 kB — the cap ChatGPT's app
# marketplace applies to an uploaded icon. Pass --palette to the generator to
# trade size against banding; 16 colours starts to step the watermark ribbon.

ICON_GLYPH := logo.svg
ICON_OUT ?= caddy/icons
ICON_IMAGE := mcp-icon:local
# Empty defers to the LADDER in the generator (512/192/180/48/32/16), which is
# the single source of truth for the set and already carries the 16/32/48 that
# --ico packs. Set a comma-separated list only to override it for a one-off.
ICON_SIZES ?=
# Narrow a run to one service: make icons ICON_SERVICE=graphiti. nullglob
# empties the wildcard form when no service has a logo yet, but a named service
# is not a pattern and survives as a literal — hence the -f sweep below, which
# turns a typo'd name into the same "no glyphs matched" as no logos at all.
ICON_SERVICE ?=

## Regenerate the committed favicon sets from services/*/logo.svg
icons:
	@set -euo pipefail; \
	shopt -s nullglob; \
	for f in tools/icon/generate.mjs tools/icon/logo.svg; do \
		if [ ! -f "$$f" ]; then echo "missing $$f" >&2; exit 1; fi; \
	done; \
	pattern="services/$(if $(ICON_SERVICE),$(ICON_SERVICE),*)/$(ICON_GLYPH)"; \
	glyphs=($$pattern); \
	for glyph in "$${glyphs[@]}"; do \
		if [ ! -f "$$glyph" ]; then glyphs=(); break; fi; \
	done; \
	if [ $${#glyphs[@]} -eq 0 ]; then \
		echo "no glyphs matched $$pattern" >&2; exit 1; \
	fi; \
	docker build --quiet --tag "$(ICON_IMAGE)" tools/icon >/dev/null; \
	for glyph in "$${glyphs[@]}"; do \
		svc=$$(basename "$$(dirname "$$glyph")"); \
		mkdir -p "$(ICON_OUT)/$$svc"; \
		docker run --rm --user "$$(id -u):$$(id -g)" \
			--volume "$$PWD:/w" --workdir /w "$(ICON_IMAGE)" \
			"$$glyph" --out "$(ICON_OUT)/$$svc" --flat-names --ico \
			$(if $(ICON_SIZES),--sizes "$(ICON_SIZES)",); \
	done; \
	hidden=$$(git ls-files --others --ignored --exclude-standard --directory \
		"$(ICON_OUT)" 2>/dev/null | head -1); \
	if [ -n "$$hidden" ]; then \
		echo "warning: git is ignoring $$hidden — these icons cannot be" >&2; \
		echo "         committed, so the host will 404 them (see .gitignore)" >&2; \
	fi

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
