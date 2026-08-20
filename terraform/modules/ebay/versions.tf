# Only non-hashicorp-namespace providers need declaring — without this,
# terraform would resolve `auth0` to the nonexistent hashicorp/auth0.
# Version constraints live in the root module.
terraform {
  required_providers {
    auth0 = {
      source = "auth0/auth0"
    }
  }
}
