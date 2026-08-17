#!/usr/bin/env bash

#?/name     auth0-cimd-pending.sh — Report CIMD metadata URLs pending Terraform registration
#?/synopsis auth0-cimd-pending.sh
#?/description
 # Queries recent Auth0 tenant logs for authorization failures of the form
 # "Unknown client: <url>" — the signature of a CIMD-capable MCP client
 # whose metadata URL has not yet been registered in the infrastructure
 # repo's terraform (auth0_client_cimd). Prints each unique URL so it can
 # be added as a cimd_clients entry. Uses the same least-privilege GC
 # credential (read:logs is sufficient; no mutations are performed).
 #
 # Auth0 free-tier log retention is 2 days, so only recent blocks appear.
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
auth0_cimd_pending::_err() {
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
auth0_cimd_pending::_token() {
  local resp
  resp="$(curl -sS -X POST "https://${TENANT}/oauth/token" \
    -H "Content-Type: application/json" \
    -d "{\"grant_type\":\"client_credentials\",
         \"client_id\":\"${AUTH0_GC_CLIENT_ID}\",
         \"client_secret\":\"${AUTH0_GC_CLIENT_SECRET}\",
         \"audience\":\"${API}/\"}")"
  jq -er '.access_token' <<<"${resp}" || {
    auth0_cimd_pending::_err \
      "token request failed: $(jq -c 'del(.access_token)' <<<"${resp}")"
    return 1
  }
}

#@/command
 # Print CIMD metadata URLs blocked by Auth0 in recent tenant logs.
 #
 # @env     AUTH0_GC_CLIENT_ID      GC app client id (op://-sourced)
 # @env     AUTH0_GC_CLIENT_SECRET  GC app client secret (op://-sourced)
 # @env     AUTH0_GC_DOMAIN         Tenant domain [nickawilliams.us.auth0.com]
 #
 # @stdout  Unique metadata URLs pending terraform cimd_clients entry
 # @stderr  Error messages
 #
 # @exit    0              Success (including nothing pending)
 # @exit    1              API failure
 ##
auth0_cimd_pending() {
  local token
  token="$(auth0_cimd_pending::_token)" || return 1
  local -r auth=(-H "Authorization: Bearer ${token}")

  # Fetch the 100 most recent log entries and filter client-side — more
  # robust than relying on Auth0's Lucene query syntax for description
  # field matching, which varies across plan tiers.
  local logs
  logs="$(curl -sS "${auth[@]}" -G "${API}/logs" \
    --data-urlencode 'per_page=100' \
    --data-urlencode 'sort=date:-1')"

  local urls
  urls="$(jq -r \
    '[.[].description // ""]
     | map(select(test("Unknown client: ")))
     | map(capture("Unknown client: (?<url>https?://[^ ]+)").url)
     | unique[]' \
    <<<"${logs}")"

  if [[ -z "${urls}" ]]; then
    echo "no pending CIMD registrations in recent logs (2-day retention window)"
    return 0
  fi

  echo "pending CIMD registrations — add each to terraform cimd_clients:"
  while IFS= read -r url; do
    printf "  %s\n" "${url}"
  done <<<"${urls}"
}

auth0_cimd_pending "$@"
