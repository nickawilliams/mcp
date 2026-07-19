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
