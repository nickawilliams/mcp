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

variable "instance_type" {
  description = "EC2 instance type for the MCP host (arm64)"
  type        = string
  default     = "t4g.small"
}

variable "acme_email" {
  description = "Email for the Let's Encrypt account (blank = anonymous)"
  type        = string
  default     = ""
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
