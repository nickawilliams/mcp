# Service manifest
# ==============================================================================
# One module block per MCP service, every one of them pointed at the same
# ./modules/service — that module owns what every service has (registry
# identity, bearer token, DNS record, Auth0 resource server, SSM secrets) and
# exports its registry entry + token. The root aggregates those into the
# shared artifacts (Caddyfile, refresh.sh, service URLs) in locals.tf.
#
# A service whose only terraform is that common surface needs nothing but a
# block here — no directory of its own. Resources that are genuinely bespoke
# (an upstream SaaS credential with its own provider) live in a root .tf file
# named for the service, and feed their values back in through `secrets`;
# graphiti.tf is the only one so far.

module "graphiti" {
  source = "./modules/service"

  name        = "graphiti"
  path_prefix = local.path_prefix
  mcp_domain  = local.mcp_domain
  zone_id     = aws_route53_zone.mcp.zone_id
  host_ip     = aws_eip.host.public_ip

  secrets = {
    OPENAI_API_KEY = openai_project_service_account.graphiti.api_key
  }

  # FalkorDB's own auth, consumed only by services/graphiti/compose.yaml —
  # nothing outside this stack ever needs to see it, so terraform mints it.
  generated_secrets = {
    FALKORDB_PASSWORD = 32
  }
}

module "mail" {
  source = "./modules/service"

  name        = "mail"
  path_prefix = local.path_prefix
  mcp_domain  = local.mcp_domain
  zone_id     = aws_route53_zone.mcp.zone_id
  host_ip     = aws_eip.host.public_ip

  # One password per mail account; the keys are the env var names that
  # services/mail/compose.yaml interpolates. That file owns the rest of each
  # account's config (hosts, users, ports), so adding an account is a change
  # in both places.
  secrets = {
    MAIL_DEFAULT_PASSWORD  = var.mail_password_default
    MAIL_ACCOUNTS_PASSWORD = var.mail_password_accounts
    MAIL_GMAIL_PASSWORD    = var.mail_password_gmail
    MAIL_WORK_PASSWORD     = var.mail_password_work
  }
}

module "ebay" {
  source = "./modules/service"

  name        = "ebay"
  path_prefix = local.path_prefix
  mcp_domain  = local.mcp_domain
  zone_id     = aws_route53_zone.mcp.zone_id
  host_ip     = aws_eip.host.public_ip

  # eBay developer-app credentials plus the user refresh token, interpolated
  # by services/ebay/compose.yaml. The refresh token is minted out-of-band by
  # the package's local setup wizard (browser OAuth against eBay), lives ~18
  # months, and does not rotate on use — expiry means rerunning the wizard and
  # updating the 1Password item this value is sourced from. The client id is
  # not strictly secret (it appears in OAuth URLs) but rides the same path for
  # uniformity.
  secrets = {
    EBAY_CLIENT_ID          = var.ebay_client_id
    EBAY_CLIENT_SECRET      = var.ebay_client_secret
    EBAY_USER_REFRESH_TOKEN = var.ebay_user_refresh_token
  }
}

# --- State moves from the pre-module layout (2026-07-21) ----------------------
# The bearer and DNS moves below are still the only record of those addresses;
# the openai/falkordb ones are chained onto by the 2026-08-25 block that
# follows, which terraform resolves transitively.

moved {
  from = random_password.service_bearer["graphiti"]
  to   = module.graphiti.random_password.bearer
}

moved {
  from = aws_route53_record.service["graphiti"]
  to   = module.graphiti.aws_route53_record.service
}

moved {
  from = aws_ssm_parameter.openai_api_key
  to   = module.graphiti.aws_ssm_parameter.openai_api_key
}

moved {
  from = random_password.falkordb
  to   = module.graphiti.random_password.falkordb
}

moved {
  from = aws_ssm_parameter.falkordb_password
  to   = module.graphiti.aws_ssm_parameter.falkordb_password
}

# --- State moves onto the shared service module (2026-08-25) ------------------
# Each service's five common resources kept both their module address and
# their resource name, so they are not listed here — only the extras, which
# moved into the shared module's `secret`/`generated` for_each maps, plus the
# OpenAI service account, which moved out to graphiti.tf.
#
# The 2026-07-21 block above no longer carries a move for that service
# account. Keeping it would declare the same pair of addresses in both
# directions at once; state passed through the intermediate address over a
# month ago, so only the outbound half is still meaningful.

moved {
  from = module.graphiti.openai_project_service_account.graphiti
  to   = openai_project_service_account.graphiti
}

moved {
  from = module.graphiti.aws_ssm_parameter.openai_api_key
  to   = module.graphiti.aws_ssm_parameter.secret["OPENAI_API_KEY"]
}

moved {
  from = module.graphiti.random_password.falkordb
  to   = module.graphiti.random_password.generated["FALKORDB_PASSWORD"]
}

moved {
  from = module.graphiti.aws_ssm_parameter.falkordb_password
  to   = module.graphiti.aws_ssm_parameter.generated["FALKORDB_PASSWORD"]
}

moved {
  from = module.mail.aws_ssm_parameter.account_password["default"]
  to   = module.mail.aws_ssm_parameter.secret["MAIL_DEFAULT_PASSWORD"]
}

moved {
  from = module.mail.aws_ssm_parameter.account_password["accounts"]
  to   = module.mail.aws_ssm_parameter.secret["MAIL_ACCOUNTS_PASSWORD"]
}

moved {
  from = module.mail.aws_ssm_parameter.account_password["gmail"]
  to   = module.mail.aws_ssm_parameter.secret["MAIL_GMAIL_PASSWORD"]
}

moved {
  from = module.mail.aws_ssm_parameter.account_password["work"]
  to   = module.mail.aws_ssm_parameter.secret["MAIL_WORK_PASSWORD"]
}

moved {
  from = module.ebay.aws_ssm_parameter.client_id
  to   = module.ebay.aws_ssm_parameter.secret["EBAY_CLIENT_ID"]
}

moved {
  from = module.ebay.aws_ssm_parameter.client_secret
  to   = module.ebay.aws_ssm_parameter.secret["EBAY_CLIENT_SECRET"]
}

moved {
  from = module.ebay.aws_ssm_parameter.user_refresh_token
  to   = module.ebay.aws_ssm_parameter.secret["EBAY_USER_REFRESH_TOKEN"]
}
