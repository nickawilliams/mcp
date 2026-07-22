# graphiti — knowledge-graph long-term-memory MCP service.
# Owns everything keyed by this service: its registry identity (exported for
# the platform's aggregation), bearer token, DNS record, file delivery, and
# service-specific extras (OpenAI credential, FalkorDB password). Platform
# singletons (host, Caddy, refresh.sh) live in the root module, which wires
# in the shared context via this module's variables.

locals {
  # Registry identity — must agree with this service's compose.yaml.
  service = {
    subdomain = "graphiti"
    upstream  = "graphiti-mcp:8000"
    path      = "/mcp"
    data_dirs = ["falkordb"]
  }

  # This service's payload directory (relative reach across the repo:
  # modules live under terraform/, payloads under services/).
  service_dir = "${path.module}/../../../services/graphiti"

  # Everything in the service directory ships to the host at the same
  # relative path, except documentation.
  files = {
    for f in fileset(local.service_dir, "**") :
    f => file("${local.service_dir}/${f}")
    if !endswith(f, ".md") && !startswith(f, "docs/")
  }
}

resource "random_password" "bearer" {
  length  = 48
  special = false
}

resource "aws_route53_record" "service" {
  zone_id = var.zone_id
  name    = "${local.service.subdomain}.${var.mcp_domain}"
  type    = "A"
  ttl     = 300
  records = [var.host_ip]
}

resource "aws_ssm_parameter" "files" {
  for_each = local.files

  name  = "/${var.path_prefix}/config/services/graphiti/${each.key}"
  type  = "String"
  value = each.value
}

# Service-specific extras
# ==============================================================================
# Secret basenames must be unique across services (refresh.sh flattens all of
# /secrets/* into the host's single .env).

resource "openai_project_service_account" "graphiti" {
  name       = "graphiti-mcp"
  project_id = var.openai_project_id
}

resource "aws_ssm_parameter" "openai_api_key" {
  name  = "/${var.path_prefix}/secrets/OPENAI_API_KEY"
  type  = "SecureString"
  value = openai_project_service_account.graphiti.api_key
}

resource "random_password" "falkordb" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "falkordb_password" {
  name  = "/${var.path_prefix}/secrets/FALKORDB_PASSWORD"
  type  = "SecureString"
  value = random_password.falkordb.result
}
