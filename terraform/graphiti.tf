# graphiti (service-specific resources)
# ==============================================================================
# Everything only graphiti needs: its LLM credential and its FalkorDB store
# password. The generic per-service pieces (DNS record, Caddy vhost, bearer
# token, file delivery) come from the `services` map — this file is the
# pattern for service-owned extras. Secret basenames must be unique across
# services (refresh.sh flattens them into one .env).

resource "openai_project_service_account" "graphiti" {
  name       = "graphiti-mcp"
  project_id = openai_project.mcp.id
}

resource "aws_ssm_parameter" "openai_api_key" {
  name  = "/${local.path_prefix}/secrets/OPENAI_API_KEY"
  type  = "SecureString"
  value = openai_project_service_account.graphiti.api_key
}

resource "random_password" "falkordb" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "falkordb_password" {
  name  = "/${local.path_prefix}/secrets/FALKORDB_PASSWORD"
  type  = "SecureString"
  value = random_password.falkordb.result
}
