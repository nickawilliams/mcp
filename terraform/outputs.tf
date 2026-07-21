output "host_instance_id" {
  description = "EC2 instance id (for SSM Session Manager / make ssm)"
  value       = aws_instance.host.id
}

output "host_eip" {
  description = "Public IP of the MCP host"
  value       = aws_eip.host.public_ip
}

output "service_urls" {
  description = "MCP endpoint URLs"
  value       = { for k, v in local.services : k => "https://${v.subdomain}.${local.mcp_domain}/" }
}

output "service_bearer_tokens" {
  description = "Per-service bearer tokens (Authorization: Bearer <token>)"
  value       = local.service_tokens
  sensitive   = true
}

output "zone_id" {
  description = "mcp.nickawilliams.com hosted zone id (this stack's hook for future services)"
  value       = aws_route53_zone.mcp.zone_id
}
