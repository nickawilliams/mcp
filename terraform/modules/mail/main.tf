# mail — multi-account IMAP/SMTP MCP service (tecnologicachile/mail-mcp
# behind an in-container supergateway stdio->HTTP bridge).
# Owns everything keyed by this service: its registry identity (exported for
# the platform's aggregation), bearer token, DNS record, and service-specific
# extras (one password per mail account). Platform singletons (host, Caddy)
# live in the root module, which wires in the shared context via this
# module's variables. Files (compose, Dockerfile) reach the host via the git
# checkout — services/mail/ — not via terraform.

locals {
  # Registry identity — must agree with this service's compose.yaml and its
  # vhost block in caddy/Caddyfile.
  service = {
    subdomain = "mail"
  }

  # The managed account set is defined by the caller's map keys. for_each
  # may not range over a sensitive map, so the ids are unwrapped — the ids
  # themselves aren't secret, only the password values are (and those stay
  # sensitive).
  account_ids = toset(nonsensitive(keys(var.account_passwords)))
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
# ({$MCP_TOKEN_MAIL} in caddy/Caddyfile). Secret basenames must be unique
# across services (refresh.sh flattens all of /secrets/* into the host's
# single .env).
resource "aws_ssm_parameter" "token" {
  name  = "/${var.path_prefix}/secrets/MCP_TOKEN_MAIL"
  type  = "SecureString"
  value = random_password.bearer.result
}

# Service-specific extras
# ==============================================================================
# One SecureString per account password; basenames (MAIL_<ID>_PASSWORD)
# unique repo-wide. Compose fans each out to the app's IMAP+SMTP pair.

resource "aws_ssm_parameter" "account_password" {
  for_each = local.account_ids

  name  = "/${var.path_prefix}/secrets/MAIL_${upper(each.key)}_PASSWORD"
  type  = "SecureString"
  value = var.account_passwords[each.key]
}

# OAuth audience (C4)
# ==============================================================================
# MCP clients send this service's URL as the RFC 8707 `resource` param, and
# the tenant's compatibility profile maps it to an audience by exact string
# match — but clients disagree on the canonical form of a bare origin:
# claude.ai/ChatGPT send the configured URL verbatim (no trailing slash),
# while Claude Code sends the WHATWG-normalized form (trailing slash; a JS
# URL of an origin always carries "/" as its path). Identifiers are
# immutable, so each form is its own resource server; Caddy whitelists both
# audiences. rfc9068_profile issues standard at+jwt access
# tokens that Caddy verifies offline via the tenant JWKS. Third-party (DCR)
# clients always need a client grant even under an allow_all policy, so the
# default_for grant pre-authorizes every dynamically-registered client for
# user-delegated access (spike-verified 2026-08-07; see ROADMAP C4).

# allow_offline_access lets Auth0 honor the offline_access scope and issue
# refresh tokens; without it every session hard-expires with the 24 h access
# token and the only recovery is interactive reauth. Renewal cadence is then
# governed by each client's refresh-token policy (the CIMD client's lives in
# the infrastructure identity module; DCR clients use tenant defaults).
resource "auth0_resource_server" "service" {
  name                 = "mcp-${local.service.subdomain}"
  identifier           = "https://${local.service.subdomain}.${var.mcp_domain}"
  signing_alg          = "RS256"
  token_dialect        = "rfc9068_profile"
  allow_offline_access = true
}

resource "auth0_resource_server" "service_slashed" {
  name                 = "mcp-${local.service.subdomain}-slashed"
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

resource "auth0_client_grant" "third_party_default_slashed" {
  audience     = auth0_resource_server.service_slashed.identifier
  default_for  = "third_party_clients"
  subject_type = "user"
  scopes       = []
}
