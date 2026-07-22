# Only the non-hashicorp-namespace provider needs declaring — without this,
# terraform would resolve `openai` to the nonexistent hashicorp/openai.
# Version constraints live in the root module.
terraform {
  required_providers {
    openai = {
      source = "jianyuan/openai"
    }
  }
}
