variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-west-1"
}

variable "environment" {
  description = "Deployment environment (single-instance: always common)"
  type        = string
  default     = "common"
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
