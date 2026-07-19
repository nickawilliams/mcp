# DNS
# ==============================================================================
# This stack owns its delegated subdomain end to end: the mcp.nickawilliams.com
# child zone plus the NS delegation record in the root zone (owned by the
# infrastructure core, read via remote state). Service records live in main.tf.

resource "aws_route53_zone" "mcp" {
  name = "mcp.${var.domain_primary}"
}

resource "aws_route53_record" "ns" {
  zone_id = local.common.zone_id
  name    = aws_route53_zone.mcp.name
  type    = "NS"
  ttl     = 300

  records = aws_route53_zone.mcp.name_servers
}
