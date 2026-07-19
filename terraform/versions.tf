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

    openai = {
      source  = "jianyuan/openai"
      version = "~> 0.5"
    }
  }
}
