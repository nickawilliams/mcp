# 1Password write-back
# ==============================================================================
# The Infrastructure vault holds automation-consumed secrets; each secret is
# managed in its producer's repo, and this repo produces the per-service
# bearer tokens. Writing them back as mcp-bearer-<service> items keeps the
# vault a faithful view of what terraform last applied — clients read
# op://Infrastructure/mcp-bearer-<service>/password. Values persist in state
# (same accepted tradeoff as the tokens themselves).

locals {
  # 1Password analog of the AWS default_tags in providers.tf: the `terraform`
  # tag is the list-level "machine-managed" facet; the metadata section
  # carries the same k/v vocabulary as the AWS tag set. section_map is an
  # attribute, so per-item additions compose with merge().
  op_tags = ["terraform"]
  op_metadata = {
    metadata = {
      field_map = {
        scope       = { value = "nickawilliams" }
        environment = { value = var.target_environment }
        repository  = { value = "mcp" }
        owner       = { value = "terraform:mcp" }
      }
    }
  }
}

data "onepassword_vault" "infrastructure" {
  name = "Infrastructure"
}

resource "onepassword_item" "bearer" {
  for_each = local.services

  vault    = data.onepassword_vault.infrastructure.uuid
  title    = "mcp-bearer-${each.key}"
  category = "password"
  url      = "https://${each.value.subdomain}.${local.mcp_domain}/"
  password = local.service_tokens[each.key]

  tags        = local.op_tags
  section_map = local.op_metadata
}

# The Auth0 GC maintenance credential (see auth0.tf), read by the Makefile as
# op://Infrastructure/auth0-client-mcp-gc/{username,password}. The secret is
# whatever Auth0 already holds — auth0_client_credentials.gc leaves it unset
# and reads it back — so adopting this item did not rotate it. Rotate with:
#   terraform apply -replace=auth0_client_credentials.gc
resource "onepassword_item" "auth0_gc" {
  vault    = data.onepassword_vault.infrastructure.uuid
  title    = "auth0-client-mcp-gc"
  category = "login"
  url      = "https://${local.common.auth0_domain}/"
  username = auth0_client.gc.client_id
  password = auth0_client_credentials.gc.client_secret

  # The scope list this item used to carry by hand now lives in auth0.tf; what
  # is left is the provenance a reader of the vault cannot derive from code.
  note_value = "Management API client for scripts/auth0-gc.sh. Minted 2026-08-09 via the auth0 CLI; adopted into terraform (mcp/terraform/auth0.tf) 2026-08-17, which is now the source of truth for its scopes."

  tags        = local.op_tags
  section_map = local.op_metadata
}
