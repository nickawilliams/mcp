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

# OAuth audience (C4)
# ==============================================================================
# MCP clients send this service's URL as the RFC 8707 `resource` param, and
# the tenant's compatibility profile maps it to an audience by exact string
# match, so the identifier below must be byte-identical to what clients ask
# for. The trailing slash is what makes that a single string rather than
# two: Claude Code parses the URL with the WHATWG URL API, where a bare
# origin always carries "/" as its path, so it requests the slashed form
# however it is configured; claude.ai takes the audience from the RFC 9728
# metadata document Caddy serves, so pointing that at the slashed form moves
# it too (proven 2026-08-22 on ebay — see caddy/Caddyfile). Before that each
# service ran one resource server per form, costing two of the free plan's
# ten. rfc9068_profile issues standard at+jwt access tokens that Caddy
# verifies offline via the tenant JWKS. Third-party (DCR and CIMD) clients
# always need a client grant even under an allow_all policy, so the
# default_for grant pre-authorizes every dynamically-registered client for
# user-delegated access (spike-verified 2026-08-07; see ROADMAP C4).

# allow_offline_access lets Auth0 honor the offline_access scope and issue
# refresh tokens; without it every session hard-expires with the 24 h access
# token and the only recovery is interactive reauth. Renewal cadence is then
# governed by each client's refresh-token policy (the CIMD client's lives in
# the infrastructure identity module; DCR clients use tenant defaults).
resource "auth0_resource_server" "service" {
  name                 = "mcp-${local.service.subdomain}"
  identifier           = "https://${local.service.subdomain}.${var.mcp_domain}/"
  signing_alg          = "RS256"
  token_dialect        = "rfc9068_profile"
  allow_offline_access = true
}

resource "auth0_client_grant" "third_party_default" {
  audience     = auth0_resource_server.service.identifier
  default_for  = "third_party_clients"
  subject_type = "user"
  scopes       = []
}
