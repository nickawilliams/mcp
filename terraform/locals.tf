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

  # Aggregated service registry. Each service module (see services.tf) owns
  # its identity and exports it here; platform-shared derivations (service
  # URLs) come from these maps. Files reach the host via the git checkout,
  # so the registry carries only what terraform itself still consumes.
  services = {
    graphiti = module.graphiti.service
    mail     = module.mail.service
  }

  service_tokens = {
    graphiti = module.graphiti.token
    mail     = module.mail.token
  }

  user_data = templatefile("${path.module}/files/cloud-init.sh.tftpl", {
    region      = var.aws_region
    path_prefix = local.path_prefix
  })
}
