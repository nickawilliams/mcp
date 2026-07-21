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

# deploy: tell the host to re-pull rendered config/secrets from SSM and
# reconcile compose (services restart only if their config changed). Run after
# `make apply` whenever config changed. Fetches refresh.sh fresh first, so the
# sync logic itself is deployable through the same path.
SSM_CONFIG = /common/mcp/config

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
