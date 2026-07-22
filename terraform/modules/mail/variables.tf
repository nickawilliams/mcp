variable "path_prefix" {
  description = "SSM path prefix for the stack (e.g. common/mcp)"
  type        = string
}

variable "mcp_domain" {
  description = "Parent MCP domain; the service subdomain is created under it"
  type        = string
}

variable "zone_id" {
  description = "Route53 hosted zone id for the MCP domain"
  type        = string
}

variable "host_ip" {
  description = "Public IP of the shared MCP host (DNS A record target)"
  type        = string
}

variable "account_passwords" {
  description = "Mail account passwords keyed by account id. The keys define the managed account set: each gets a MAIL_<ID>_PASSWORD SecureString, interpolated by the account's entry in services/mail/compose.yaml (which owns the rest of the account config — hosts, users, ports)."
  type        = map(string)
  sensitive   = true

  validation {
    condition     = length(var.account_passwords) > 0
    error_message = "At least one mail account is required."
  }
}
