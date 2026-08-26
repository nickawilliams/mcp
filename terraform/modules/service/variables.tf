variable "name" {
  description = "Service name. Doubles as the subdomain, the Auth0 audience host, the icon directory, and the MCP_TOKEN_<NAME> basename, all of which have to agree anyway."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.name))
    error_message = "Service name must be lowercase alphanumeric: it becomes a DNS label and, uppercased, an env var name."
  }
}

variable "path_prefix" {
  description = "SSM path prefix for the stack (e.g. prod/mcp)"
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

variable "secrets" {
  description = "Caller-supplied secrets, keyed by the env var name they become on the host (e.g. EBAY_CLIENT_SECRET). Each gets a SecureString under the stack's secrets path; basenames must be unique across all services, since refresh.sh flattens them into one .env."
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "generated_secrets" {
  description = "Secrets terraform generates rather than receives, as env var name => password length (e.g. { FALKORDB_PASSWORD = 32 }). For values nothing outside this stack needs to know. Same basename uniqueness rule as `secrets`."
  type        = map(number)
  default     = {}
}
