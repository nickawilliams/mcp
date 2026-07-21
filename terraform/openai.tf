# OpenAI (platform)
# ==============================================================================
# One project scopes all of this stack's OpenAI usage; each service that needs
# an LLM credential mints its own project service account in its service .tf
# file (see graphiti.tf). Managed the same way as Migadu in the infrastructure
# core: an org admin key in .env drives the provider; minted keys live in
# state (private + SSE backend).
#
# NOTE: the provider/API cannot set a hard spend cap — set the monthly usage
# limit in the OpenAI dashboard as the backstop. Per-model throughput can be
# bounded later with openai_project_rate_limit once the rate_limit_ids are
# confirmed for the chosen models.

resource "openai_project" "mcp" {
  name = "mcp"
}