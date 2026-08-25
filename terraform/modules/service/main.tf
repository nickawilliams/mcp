# The platform surface every MCP service has, instantiated once per service
# from services.tf. A service is its registry identity (exported for the
# platform's aggregation), a bearer token, a DNS record, an Auth0 resource
# server, and some number of SSM secrets — this module owns all of it, so a
# service that needs nothing else needs no terraform of its own.
#
# Genuinely bespoke resources (an upstream SaaS credential, say) stay in the
# root module in that service's own .tf file, and feed their secret values
# back in through `secrets`. Platform singletons (host, Caddy) live in the
# root module too, which wires the shared context in via this module's
# variables. Files (compose, config) reach the host via the git checkout —
# services/<name>/ — not via terraform.

locals {
  # Registry identity — must agree with the service's compose.yaml and its
  # vhost block in caddy/Caddyfile.
  service = {
    subdomain = var.name
  }

  # for_each may not range over a sensitive map, so the names are unwrapped.
  # The names themselves aren't secret, only the values are (and those stay
  # sensitive).
  secret_names = toset(nonsensitive(keys(var.secrets)))
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
# ({$MCP_TOKEN_<NAME>} in caddy/Caddyfile).
resource "aws_ssm_parameter" "token" {
  name  = "/${var.path_prefix}/secrets/MCP_TOKEN_${upper(var.name)}"
  type  = "SecureString"
  value = random_password.bearer.result
}

# Service secrets
# ==============================================================================
# Two kinds, both landing in the same place: values the caller supplies, and
# values terraform generates because nothing outside this stack needs to know
# them. Both are keyed by the env var name they become — refresh.sh flattens
# all of /secrets/* into the host's single .env using the last path segment,
# so basenames must be unique across every service, not just within one.

resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_names

  name  = "/${var.path_prefix}/secrets/${each.key}"
  type  = "SecureString"
  value = var.secrets[each.key]
}

resource "random_password" "generated" {
  for_each = var.generated_secrets

  length  = each.value
  special = false
}

resource "aws_ssm_parameter" "generated" {
  for_each = var.generated_secrets

  name  = "/${var.path_prefix}/secrets/${each.key}"
  type  = "SecureString"
  value = random_password.generated[each.key].result
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
