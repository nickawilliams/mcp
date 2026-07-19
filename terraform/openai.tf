# OpenAI
# ==============================================================================
# graphiti's LLM + embedding credential is minted here as a project-scoped
# service-account key and wired into Parameter Store (see main.tf). Managed the
# same way as Migadu in the infrastructure core: an org admin key in .env drives
# the provider; the minted key lives in state (private + SSE backend).
#
# NOTE: the provider/API cannot set a hard spend cap — set the monthly usage
# limit in the OpenAI dashboard as the backstop. Per-model throughput can be
# bounded later with openai_project_rate_limit once the rate_limit_ids are
# confirmed for the chosen models.

resource "openai_project" "mcp" {
  name = "mcp"
}

resource "openai_project_service_account" "graphiti" {
  name       = "graphiti-mcp"
  project_id = openai_project.mcp.id
}