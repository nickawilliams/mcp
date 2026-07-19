# The infrastructure core owns the root zone and exposes it as a hook; this
# stack reads it (and nothing else) via remote state. The dependency arrow only
# points inward: [ infrastructure/common ] <-- [ mcp ].
data "terraform_remote_state" "common" {
  backend = "s3"

  config = {
    bucket = "terraform-state-nickawilliams"
    key    = "525999333867/us-west-1/nickawilliams/common/infrastructure/terraform.tfstate"
    region = "us-west-1"
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Standard AL2023 arm64. The name is pinned to al2023-ami-2023.* so it matches
# ONLY the standard image, never the minimal (which omits the SSM agent) or the
# ecs variant. (The /aws/service/ami-al2023 public SSM params are SCP-blocked here.)
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"] # amazon

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  common      = data.terraform_remote_state.common.outputs
  name_prefix = "${var.environment}-${var.application_name}" # common-mcp
  path_prefix = replace(local.name_prefix, "-", "/")         # common/mcp (SSM paths)
  mcp_domain  = "mcp.${var.domain_primary}"

  # The framework's generalization: +1 service = +1 entry. Each gets a DNS
  # record, a bearer-gated Caddy vhost, and (its own) compose service.
  services = {
    graphiti = {
      subdomain = "graphiti"
      upstream  = "graphiti-mcp:8000"
    }
  }

  caddyfile = templatefile("${path.module}/files/Caddyfile.tftpl", {
    mcp_domain   = local.mcp_domain
    acme_email   = var.acme_email
    services     = local.services
    bearer_token = random_password.bearer.result
  })

  user_data = templatefile("${path.module}/files/cloud-init.sh.tftpl", {
    region      = var.aws_region
    path_prefix = local.path_prefix
  })
}
