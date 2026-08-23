# ebay — eBay Sell-API MCP service (YosefHayim/ebay-mcp from npm, running
# its native streamable-HTTP entrypoint — no supergateway bridge).
# Owns everything keyed by this service: its registry identity (exported for
# the platform's aggregation), bearer token, DNS record, and service-specific
# extras (the eBay app + user credentials). Platform singletons (host, Caddy)
# live in the root module, which wires in the shared context via this
# module's variables. Files (compose, Dockerfile) reach the host via the git
# checkout — services/ebay/ — not via terraform.

locals {
  # Registry identity — must agree with this service's compose.yaml and its
  # vhost block in caddy/Caddyfile.
  service = {
    subdomain = "ebay"
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
# ({$MCP_TOKEN_EBAY} in caddy/Caddyfile). Secret basenames must be unique
# across services (refresh.sh flattens all of /secrets/* into the host's
# single .env).
resource "aws_ssm_parameter" "token" {
  name  = "/${var.path_prefix}/secrets/MCP_TOKEN_EBAY"
  type  = "SecureString"
  value = random_password.bearer.result
}

# Service-specific extras
# ==============================================================================
# eBay developer-app credentials plus the user refresh token, interpolated by
# services/ebay/compose.yaml. The refresh token is minted out-of-band by the
# package's local setup wizard (browser OAuth against eBay), lives ~18 months,
# and does not rotate on use — expiry means rerunning the wizard and updating
# the 1Password item this value is sourced from. The client id is not strictly
# secret (it appears in OAuth URLs) but rides the same path for uniformity.

resource "aws_ssm_parameter" "client_id" {
  name  = "/${var.path_prefix}/secrets/EBAY_CLIENT_ID"
  type  = "SecureString"
  value = var.client_id
}

resource "aws_ssm_parameter" "client_secret" {
  name  = "/${var.path_prefix}/secrets/EBAY_CLIENT_SECRET"
  type  = "SecureString"
  value = var.client_secret
}

resource "aws_ssm_parameter" "user_refresh_token" {
  name  = "/${var.path_prefix}/secrets/EBAY_USER_REFRESH_TOKEN"
  type  = "SecureString"
  value = var.user_refresh_token
}

# OAuth audience (C4)
# ==============================================================================
# One resource server per service, keyed on the trailing-slash form of the
# origin — the single audience every client family agrees on, proven here on
# 2026-08-22 (see caddy/Caddyfile). See modules/mail/main.tf for the full
# rationale (rfc9068_profile, offline_access, default_for grants).

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
