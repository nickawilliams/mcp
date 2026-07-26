# graphiti — knowledge-graph long-term-memory MCP service.
# Owns everything keyed by this service: its registry identity (exported for
# the platform's aggregation), bearer token, DNS record, and service-specific
# extras (OpenAI credential, FalkorDB password). Platform singletons (host,
# Caddy) live in the root module, which wires in the shared context via this
# module's variables. Files (compose, config) reach the host via the git
# checkout — services/graphiti/ — not via terraform.

locals {
  # Registry identity — must agree with this service's compose.yaml and its
  # vhost block in caddy/Caddyfile.
  service = {
    subdomain = "graphiti"
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

# The token rides the secrets path so refresh.sh lands it in the host .env,
# where compose hands it to Caddy for this service's vhost gate
# ({$MCP_TOKEN_GRAPHITI} in caddy/Caddyfile). Secret basenames must be
# unique across services (refresh.sh flattens all of /secrets/* into the
# host's single .env).
resource "aws_ssm_parameter" "token" {
  name  = "/${var.path_prefix}/secrets/MCP_TOKEN_GRAPHITI"
  type  = "SecureString"
  value = random_password.bearer.result
}

# Service-specific extras
# ==============================================================================

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
