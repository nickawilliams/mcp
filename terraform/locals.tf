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
  # its identity and exports it here; everything platform-shared — the Caddy
  # vhosts, refresh.sh data dirs, service URLs — derives from these maps.
  # `path` is the upstream image's MCP endpoint; Caddy maps the bare hostname
  # onto it so clients never need to know it. `data_dirs` are bind-mount
  # targets created under /opt/mcp/data (the persistent EBS volume).
  services = {
    graphiti = module.graphiti.service
  }

  service_tokens = {
    graphiti = module.graphiti.token
  }

  # Platform dirs (caddy) + every service's declared data dirs.
  data_dirs = concat(
    ["caddy", "caddy-config"],
    flatten([for _, svc in local.services : svc.data_dirs]),
  )

  caddyfile = templatefile("${path.module}/files/Caddyfile.tftpl", {
    mcp_domain = local.mcp_domain
    acme_email = var.acme_email
    services   = local.services
    tokens     = local.service_tokens
  })

  refresh_sh = templatefile("${path.module}/files/refresh.sh.tftpl", {
    region      = var.aws_region
    path_prefix = local.path_prefix
    data_dirs   = local.data_dirs
  })

  # Platform files delivered to the host. Service payloads are delivered by
  # each service's module (aws_ssm_parameter.files); refresh.sh pulls the
  # whole config/ path regardless of which module created a param.
  config_files = {
    "docker-compose.yaml" = file("${path.module}/../docker-compose.yaml")
    "Dockerfile.caddy"    = file("${path.module}/files/Dockerfile.caddy")
    ".dockerignore"       = file("${path.module}/files/dockerignore")
    "refresh.sh"          = local.refresh_sh
    "caddy/Caddyfile"     = local.caddyfile
  }

  user_data = templatefile("${path.module}/files/cloud-init.sh.tftpl", {
    region      = var.aws_region
    path_prefix = local.path_prefix
  })
}
