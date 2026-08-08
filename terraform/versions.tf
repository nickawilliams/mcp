terraform {
  required_version = "~> 1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3"
    }

    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.3"
    }

    openai = {
      source  = "jianyuan/openai"
      version = "~> 0.5"
    }

    auth0 = {
      source  = "auth0/auth0"
      version = "~> 1.54"
    }
  }
}
