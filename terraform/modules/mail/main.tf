# mail — multi-account IMAP/SMTP MCP service (tecnologicachile/mail-mcp
# behind an in-container supergateway stdio->HTTP bridge).
# Owns everything keyed by this service: its registry identity (exported for
# the platform's aggregation), bearer token, DNS record, file delivery, and
# service-specific extras (one password per mail account). Platform
# singletons (host, Caddy, refresh.sh) live in the root module, which wires
# in the shared context via this module's variables.

locals {
  # Registry identity — must agree with this service's compose.yaml.
  service = {
    subdomain = "mail"
    upstream  = "mail-mcp:8080"
    path      = "/mcp"
    data_dirs = []
  }

  # This service's payload directory (relative reach across the repo:
  # modules live under terraform/, payloads under services/).
  service_dir = "${path.module}/../../../services/mail"

  # Everything in the service directory ships to the host at the same
  # relative path, except documentation.
  files = {
    for f in fileset(local.service_dir, "**") :
    f => file("${local.service_dir}/${f}")
    if !endswith(f, ".md") && !startswith(f, "docs/")
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

resource "aws_ssm_parameter" "files" {
  for_each = local.files

  name  = "/${var.path_prefix}/config/services/mail/${each.key}"
  type  = "String"
  value = each.value
}

# Service-specific extras
# ==============================================================================
# One SecureString per account password. Basenames (MAIL_<ID>_PASSWORD) must
# stay unique repo-wide (refresh.sh flattens all of /secrets/* into the
# host's single .env); compose fans each out to the app's IMAP+SMTP pair.

resource "aws_ssm_parameter" "account_password" {
  for_each = local.account_ids

  name  = "/${var.path_prefix}/secrets/MAIL_${upper(each.key)}_PASSWORD"
  type  = "SecureString"
  value = var.account_passwords[each.key]
}
