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
