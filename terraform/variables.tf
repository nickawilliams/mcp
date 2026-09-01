variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-west-1"
}

# `common` is deliberately not a legal value. It is the partition for what the
# environment axis does not partition — registrations, root zones, the Auth0
# tenant — and this stack is a production workload, not one of those. See
# infrastructure/docs/environments.md.
variable "target_environment" {
  description = "Deployment tier for every resource in this root"
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^(dev|stage|prod)$", var.target_environment))
    error_message = "target_environment must be one of: dev, stage, prod."
  }
}

variable "application_name" {
  description = "Name of the containing service or application"
  type        = string
  default     = "mcp"
}

variable "domain_primary" {
  description = "Primary Domain (root zone owned by the infrastructure core)"
  type        = string
  default     = "nickawilliams.com"
}

# Non-production tiers live on their own registered domain rather than under
# a subdomain of the primary, so that a non-prod host cannot set cookies the
# production site honours and does not count as same-site for CSRF purposes —
# browsers draw that boundary at the registrable domain. Not yet registered;
# referenced only by the non-prod branch of local.mcp_domain.
variable "domain_nonprod" {
  description = "Registered domain hosting non-production tiers"
  type        = string
  default     = "nickawilliams.dev"
}

variable "op_service_account_token" {
  description = "1Password service account token (op://-sourced via .env)"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type for the MCP host (arm64)"
  type        = string
  default     = "t4g.small"
}

# Mail account passwords (op://-sourced via .env as TF_VAR_*). Scalars, not a
# map: `op run` only resolves values that are exactly an op:// reference.

variable "mail_password_default" {
  description = "Password for the 'default' mail account (Migadu nick@)"
  type        = string
  sensitive   = true
}

variable "mail_password_accounts" {
  description = "Password for the 'accounts' mail account (Migadu accounts@)"
  type        = string
  sensitive   = true
}

variable "mail_password_gmail" {
  description = "App password for the 'gmail' mail account (personal Gmail)"
  type        = string
  sensitive   = true
}

variable "mail_password_work" {
  description = "App password for the 'work' mail account (Clearstory Gmail)"
  type        = string
  sensitive   = true
}

# The 'microsoft' account (Live.com personal) has no password: Microsoft
# retired basic auth for personal accounts, so it runs on two OAuth refresh
# tokens with disjoint scopes (IMAP XOAUTH2 vs Graph Mail.Send). MSA refresh
# tokens live ~90 days; re-mint with `make maintenance/microsoft-tokens`,
# then `make apply && make deploy`.

variable "mail_token_microsoft_imap" {
  description = "OAuth2 refresh token for the 'microsoft' account's IMAP XOAUTH2"
  type        = string
  sensitive   = true
}

variable "mail_token_microsoft_graph" {
  description = "OAuth2 refresh token for the 'microsoft' account's Graph sending"
  type        = string
  sensitive   = true
}

# eBay developer-app credentials for the ebay service (op://-sourced via .env
# as TF_VAR_*; same scalar-not-map constraint as the mail passwords). The
# refresh token comes from the ebay-mcp package's local setup wizard.

variable "ebay_client_id" {
  description = "eBay developer-app client id (App ID)"
  type        = string
  sensitive   = true
}

variable "ebay_client_secret" {
  description = "eBay developer-app client secret (Cert ID)"
  type        = string
  sensitive   = true
}

variable "ebay_user_refresh_token" {
  description = "eBay user OAuth refresh token (~18-month lifetime; reseed on expiry)"
  type        = string
  sensitive   = true
}
