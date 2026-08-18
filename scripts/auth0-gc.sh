#!/usr/bin/env bash

#?/name     auth0-gc.sh — Garbage-collect Auth0 DCR client debris
#?/synopsis auth0-gc.sh [--dry-run]
#?/description
 # Every MCP client that performs Dynamic Client Registration mints a
 # permanent third-party application (client_id `tpc_*`) in the Auth0
 # tenant, and the free plan caps Applications at 10 — interrupted OAuth
 # flows therefore accumulate debris that eventually blocks new client
 # registrations (403 "limit of entities"). This script runs two passes
 # over all DCR clients:
 #
 # Pass 1 — normalize: sets app_type=native on any DCR client whose
 # callbacks contain only loopback addresses (127.0.0.1 or localhost).
 # Auth0 requires app_type=native for RFC 8252 port-agnostic loopback
 # redirect matching; without it, a client that correctly registered
 # http://127.0.0.1/callback (no port) still fails when it presents a
 # portful redirect_uri at /authorize. Requires update:clients scope.
 #
 # Pass 2 — gc: deletes tpc_* clients that have zero user grants AND no
 # tenant-log activity in the retention window — a registration nothing
 # ever finished. Active clients always hold a grant, so they are never
 # touched; an in-flight registration deleted mid-flow simply re-registers
 # on the client's next attempt (DCR is automatic). CIMD registrations
 # also receive tpc_-prefixed client ids (the metadata URL lives in
 # external_client_id), so the sweep filters on
 # external_metadata_type == "dcr" — a freshly registered CIMD client has
 # no grants yet and deleting it would not self-heal (registration is
 # admin-driven, terraform-managed in ../infrastructure).
 #
 # Credentials: a least-privilege M2M app, resolved from 1Password by the
 # Makefile wrapper (`make maintenance/gc`). Required scopes:
 #   read:clients, delete:clients, read:grants, read:logs (both passes)
 #   update:clients (normalize pass)
 # The app, its grant, and the 1Password item are terraform-managed in
 # terraform/auth0.tf — widen the scope list there, not in the dashboard.
 ##

set -euo pipefail

readonly TENANT="${AUTH0_GC_DOMAIN:-nickawilliams.us.auth0.com}"
readonly API="https://${TENANT}/api/v2"

#@/private
 # Log an error message to STDERR.
 #
 # @operand <message...>   Error message text
 # @stderr                 Timestamped error message
 ##
auth0_gc::_err() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#@/private
 # Mint a Management API access token via client credentials.
 #
 # @env     AUTH0_GC_CLIENT_ID      GC app client id
 # @env     AUTH0_GC_CLIENT_SECRET  GC app client secret
 #
 # @stdout                 Access token
 # @exit    1              Token request failed
 ##
auth0_gc::_token() {
  local resp
  resp="$(curl -sS -X POST "https://${TENANT}/oauth/token" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"client_credentials\",
         \"client_id\":\"${AUTH0_GC_CLIENT_ID}\",
         \"client_secret\":\"${AUTH0_GC_CLIENT_SECRET}\",
         \"audience\":\"${API}/\"}")"
  jq -er '.access_token' <<<"${resp}" || {
    auth0_gc::_err "token request failed: $(jq -c 'del(.access_token)' <<<"${resp}")"
    return 1
  }
}

#@/command
 # Normalize loopback DCR clients to app_type=native, then delete
 # never-authorized DCR client debris.
 #
 # @flag    --dry-run      Report candidates without mutating
 #
 # @env     AUTH0_GC_CLIENT_ID      GC app client id (op://-sourced)
 # @env     AUTH0_GC_CLIENT_SECRET  GC app client secret (op://-sourced)
 # @env     AUTH0_GC_DOMAIN         Tenant domain [nickawilliams.us.auth0.com]
 #
 # @stdout                 One line per client examined or mutated
 # @stderr                 Error messages
 #
 # @exit    0              Success (including nothing to do)
 # @exit    1              API failure
 ##
auth0_gc() {
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && dry_run=1

  local token
  token="$(auth0_gc::_token)" || return 1
  local -r auth=(-H "Authorization: Bearer ${token}")

  local clients_json
  clients_json="$(curl -sS "${auth[@]}" \
    "${API}/clients?fields=client_id,app_type,callbacks,external_metadata_type&include_fields=true&per_page=100" \
    | jq '[.[] | select(.external_metadata_type == "dcr")]')"

  if [[ "$(jq 'length' <<<"${clients_json}")" -eq 0 ]]; then
    echo "no DCR clients in tenant; nothing to do"
    return 0
  fi

  # --- Pass 1: normalize app_type=native for loopback-only clients ----------
  # Auth0 only applies RFC 8252 port-agnostic loopback matching to native
  # apps. Clients that register http://127.0.0.1/callback (correct, no port)
  # still fail at /authorize with a portful redirect_uri unless this is set.
  local normalized=0
  local cid app_type
  while IFS=$'\t' read -r cid app_type; do
    if [[ "${app_type}" == "native" ]]; then
      continue
    fi
    if (( dry_run )); then
      echo "would-normalize ${cid} (app_type=${app_type:-unset} → native)"
    else
      local patch_resp
      patch_resp="$(curl -sS -w '\n%{http_code}' -X PATCH \
        "${API}/clients/${cid}" "${auth[@]}" \
        -H "Content-Type: application/json" \
        -d '{"app_type":"native"}')"
      local patch_status
      patch_status="$(tail -1 <<<"${patch_resp}")"
      if [[ "${patch_status}" != "200" ]]; then
        auth0_gc::_err "failed to normalize ${cid} (HTTP ${patch_status})" \
          "— ensure update:clients scope on GC credential"
        return 1
      fi
      echo "normalize ${cid} (app_type=${app_type:-unset} → native)"
      normalized=$(( normalized + 1 ))
    fi
  done < <(jq -r \
    '.[] | select(
       ((.callbacks // []) | length) > 0
       and ((.callbacks // []) | all(test("^https?://(127\\.0\\.0\\.1|localhost)")))
     ) | [.client_id, (.app_type // "")] | @tsv' \
    <<<"${clients_json}")

  # --- Pass 2: delete debris (zero grants + no recent log activity) ----------
  local deleted=0
  local grants logs
  while IFS= read -r cid; do
    grants="$(curl -sS "${auth[@]}" "${API}/grants?client_id=${cid}" \
      | jq 'length')"
    if (( grants > 0 )); then
      echo "keep   ${cid} (grants=${grants})"
      continue
    fi
    # Grace for in-flight flows: any log activity in the retention window
    # (registration, auth attempt) means it may still complete — skip it
    # this run; a truly dead registration goes quiet and is collected on
    # the next.
    logs="$(curl -sS "${auth[@]}" -G "${API}/logs" \
      --data-urlencode "q=client_id:\"${cid}\"" \
      --data-urlencode "per_page=1" | jq 'length')"
    if (( logs > 0 )); then
      echo "defer  ${cid} (recent activity, no grant yet)"
      continue
    fi
    if (( dry_run )); then
      echo "would-delete ${cid}"
    else
      curl -sS -o /dev/null -w '' "${auth[@]}" -X DELETE "${API}/clients/${cid}" \
        || { auth0_gc::_err "failed to delete ${cid}"; return 1; }
      echo "delete ${cid} (no grants, no activity)"
      deleted=$(( deleted + 1 ))
    fi
  done < <(jq -r '.[].client_id' <<<"${clients_json}")

  echo "done: ${normalized} normalized, ${deleted} deleted"
}

auth0_gc "$@"
