# graphiti — knowledge-graph long-term-memory MCP service.
# Its platform surface (registry identity, bearer token, DNS record, Auth0
# resource server, SSM secrets) comes from the shared module instantiated in
# services.tf. What lives here is the one resource nothing else in the stack
# has: an OpenAI service account scoped to this stack's project, whose key is
# fed back into that module as OPENAI_API_KEY. Files (compose, config) reach
# the host via the git checkout — services/graphiti/ — not via terraform.

resource "openai_project_service_account" "graphiti" {
  name       = "graphiti-mcp"
  project_id = openai_project.mcp.id
}
