# Ops wrapper for the MCP host. Secrets are resolved from 1Password at run time
# via `op run --env-file=.env`; AWS credentials come from the ambient profile.
# Terraform lives under ./terraform (see README.md).

TF := op run --env-file=.env -- terraform -chdir=terraform

.PHONY: init fmt validate plan apply ssm logs deploy

# --- Terraform ---------------------------------------------------------------

init:
	$(TF) init

fmt:
	$(TF) fmt -recursive

validate:
	$(TF) validate

plan:
	$(TF) plan

apply:
	$(TF) apply

# --- Host ops (SSM Session Manager; no SSH) ----------------------------------
# INSTANCE resolves the host id from terraform output so no id is hard-coded.

INSTANCE = $$($(TF) output -raw host_instance_id)

ssm:
	aws ssm start-session --target "$(INSTANCE)"

logs:
	aws ssm start-session --target "$(INSTANCE)" \
		--document-name AWS-StartInteractiveCommand \
		--parameters 'command=["cd /opt/mcp && docker compose logs -f --tail=200"]'

# deploy: re-push rendered config to the host and reload (see task 4 —
# config delivery via SSM/S3 + `aws ssm send-command`). TODO: implement once
# the config-delivery mechanism lands.
deploy:
	@echo "TODO: push rendered compose/Caddyfile + reload via ssm send-command"
