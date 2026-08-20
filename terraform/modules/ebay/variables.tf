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

variable "client_id" {
  description = "eBay developer-app client id (App ID from the eBay Developer Portal)"
  type        = string
  sensitive   = true
}

variable "client_secret" {
  description = "eBay developer-app client secret (Cert ID from the eBay Developer Portal)"
  type        = string
  sensitive   = true
}

variable "user_refresh_token" {
  description = "eBay user OAuth refresh token, minted by the ebay-mcp setup wizard (~18-month lifetime; reseed on expiry)"
  type        = string
  sensitive   = true
}
