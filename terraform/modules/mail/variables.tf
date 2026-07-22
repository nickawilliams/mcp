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
  description = "Mail account passwords keyed by account id (default/accounts/gmail/work)"
  type        = map(string)
  sensitive   = true
}
