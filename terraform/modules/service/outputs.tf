output "service" {
  description = "Registry entry aggregated by the platform (DNS, service URLs)"
  value       = local.service
}

output "token" {
  description = "Bearer token gating this service's Caddy vhost"
  value       = random_password.bearer.result
  sensitive   = true
}
