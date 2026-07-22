output "service" {
  description = "Registry entry aggregated by the platform (Caddy vhost, refresh.sh data dirs, service URLs)"
  value       = local.service
}

output "token" {
  description = "Bearer token gating this service's Caddy vhost"
  value       = random_password.bearer.result
  sensitive   = true
}
