# Auth0 maintenance credential
# ==============================================================================
# The GC credential behind `make maintenance/gc` (scripts/auth0-gc.sh). That
# sweep does two things: it deletes never-authorized DCR client debris, which
# matters because Auth0 mints a permanent application per registration and the
# free plan caps applications at 10; and it normalizes loopback-only DCR
# clients to app_type native, without which Auth0 refuses the port-agnostic
# redirect matching RFC 8252 requires and a client that correctly registers
# http://127.0.0.1/callback still fails at /authorize.
#
# The credential lives here rather than in the infrastructure core because a
# client grant is a workload-repo concern — the same rule that puts the
# per-service grants in modules/* — and this repo's Management API client
# already holds client_grants CRUD. The scope list below is the source of
# truth: widening it is a diff, not a dashboard click.
#
# Adopted into terraform on 2026-08-17; the client, its grant, and the
# 1Password item all predate this and were imported rather than recreated, so
# the live secret is unchanged.

resource "auth0_client" "gc" {
  name        = "mcp-gc"
  description = "DCR debris sweep and loopback normalization (make maintenance/gc)"
  app_type    = "non_interactive"

  # The app never fronts a login, so the interactive grant types Auth0 seeds
  # every new application with are dropped.
  grant_types    = ["client_credentials"]
  is_first_party = true
}

resource "auth0_client_credentials" "gc" {
  client_id = auth0_client.gc.client_id

  authentication_method = "client_secret_post"
}

resource "auth0_client_grant" "gc" {
  client_id = auth0_client.gc.client_id
  audience  = "https://${local.common.auth0_domain}/api/v2/"

  # read:clients + delete:clients + read:grants drive the debris sweep;
  # read:logs is what distinguishes a never-authorized client from a merely
  # idle one; update:clients is the app_type normalization pass.
  scopes = [
    "delete:clients",
    "read:clients",
    "read:grants",
    "read:logs",
    "update:clients",
  ]
}
