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
