# Service manifest
# ==============================================================================
# One module block per MCP service. Each module (modules/<name>/) owns every
# resource keyed by its service — registry identity, bearer token, DNS
# record, file delivery from services/<name>/, and service-specific extras —
# and exports its registry entry + token. The root aggregates those into the
# shared artifacts (Caddyfile, refresh.sh, service URLs) in locals.tf.

module "graphiti" {
  source = "./modules/graphiti"

  path_prefix       = local.path_prefix
  mcp_domain        = local.mcp_domain
  zone_id           = aws_route53_zone.mcp.zone_id
  host_ip           = aws_eip.host.public_ip
  openai_project_id = openai_project.mcp.id
}

module "mail" {
  source = "./modules/mail"

  path_prefix = local.path_prefix
  mcp_domain  = local.mcp_domain
  zone_id     = aws_route53_zone.mcp.zone_id
  host_ip     = aws_eip.host.public_ip

  account_passwords = {
    default  = var.mail_password_default
    accounts = var.mail_password_accounts
    gmail    = var.mail_password_gmail
    work     = var.mail_password_work
  }
}

module "ebay" {
  source = "./modules/ebay"

  path_prefix = local.path_prefix
  mcp_domain  = local.mcp_domain
  zone_id     = aws_route53_zone.mcp.zone_id
  host_ip     = aws_eip.host.public_ip

  client_id          = var.ebay_client_id
  client_secret      = var.ebay_client_secret
  user_refresh_token = var.ebay_user_refresh_token
}

# --- State moves from the pre-module layout (2026-07-21) ----------------------

moved {
  from = random_password.service_bearer["graphiti"]
  to   = module.graphiti.random_password.bearer
}

moved {
  from = aws_route53_record.service["graphiti"]
  to   = module.graphiti.aws_route53_record.service
}

moved {
  from = openai_project_service_account.graphiti
  to   = module.graphiti.openai_project_service_account.graphiti
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
