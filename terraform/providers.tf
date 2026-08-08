provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Scope       = "nickawilliams"
      Environment = "common"
      Repository  = "mcp"
      Owner       = "terraform:mcp"
      Terraform   = "true"
    }
  }
}

# admin_key is read from OPENAI_ADMIN_KEY (op://-sourced via .env). This org
# admin credential drives project/service-account management, mirroring how
# MIGADU_TOKEN drives the migadu provider in the infrastructure core.
provider "openai" {}

# Authenticates as a dedicated service account whose only grant is the
# Infrastructure vault. The token is fed through a Terraform variable
# (op://-sourced via .env) rather than OP_SERVICE_ACCOUNT_TOKEN, which
# would override desktop-app auth for every `op` invocation in this
# directory. The provider shells out to the `op` CLI (>= 2.23.0).
provider "onepassword" {
  service_account_token = var.op_service_account_token
}

# Management API client scoped to resource_servers + client_grants only
# (op://Infrastructure/auth0-client-mcp-terraform, read as AUTH0_CLIENT_ID /
# AUTH0_CLIENT_SECRET via .env). Identity is a core concern: the tenant, DCR
# flag, and auth.nickawilliams.com custom domain live in the infrastructure
# repo; this repo only registers its per-service audiences against that
# tenant, whose domain arrives via remote state (same hook as zone_id).
provider "auth0" {
  domain = data.terraform_remote_state.common.outputs.auth0_domain
}
