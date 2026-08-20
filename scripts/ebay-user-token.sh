#!/usr/bin/env bash

#?/name     ebay-user-token.sh — Re-mint the eBay user refresh token
#?/synopsis ebay-user-token.sh
#?/description
 # The ebay service authenticates to eBay with a user refresh token that
 # lives ~18 months and does not rotate on use (see services/ebay/). When
 # it expires — or access is revoked from the eBay account — a new one
 # must be minted via an interactive browser consent and re-seeded into
 # 1Password, from where terraform lands it in SSM.
 #
 # This script automates everything around the consent: it opens the
 # keyset's portal-generated branded sign-in URL (always scope-correct —
 # hand-built scope lists risk invalid_scope on limited-release scopes),
 # accepts the pasted redirect landing URL, exchanges the authorization
 # code for tokens against eBay's production token endpoint, and writes
 # the refresh token back to the 1Password item. The upstream package's
 # `npx ebay-mcp setup` wizard does the same dance but cannot run
 # non-interactively and hardcodes a scope table that overshoots keyset
 # entitlements; it is not needed here.
 #
 # Credentials resolve from 1Password via the Makefile wrapper
 # (`make maintenance/ebay-token`). The write-back uses the shell `op`
 # (desktop-app auth), not the terraform service account. Production
 # only; macOS only (BSD date, `open`). See services/ebay/docs/setup.md.
 ##

set -euo pipefail

readonly TOKEN_URL="https://api.ebay.com/identity/v1/oauth2/token"
readonly OP_VAULT="Infrastructure"
readonly OP_ITEM="ebay-client-mcp"
readonly OP_FIELD="user-refresh-token"

# The app credentials arrive under their terraform variable names (the same
# .env op:// refs terraform consumes); normalize to script-local constants.
readonly EBAY_CLIENT_ID="${TF_VAR_ebay_client_id:-}"
readonly EBAY_CLIENT_SECRET="${TF_VAR_ebay_client_secret:-}"

#@/private
 # Log an error message to STDERR.
 #
 # @operand <message...>   Error message text
 # @stderr                 Timestamped error message
 ##
ebay_user_token::_err() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#@/private
 # Validate that required tools are installed.
 #
 # @operand <commands...>  Command names to check
 # @stderr                 Missing command names
 # @exit    0              All commands found
 # @exit    1              One or more commands missing
 ##
ebay_user_token::_check_deps() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" &> /dev/null; then
      ebay_user_token::_err "Required command not found: ${cmd}"
      return 1
    fi
  done
}

#@/private
 # Extract the raw (still URL-encoded) authorization code from a pasted
 # redirect landing URL. The code is kept encoded on purpose: eBay hands
 # it back application/x-www-form-urlencoded, which is exactly the
 # encoding the token-exchange POST body needs — decoding and re-encoding
 # only adds failure modes.
 #
 # @operand <url>          Redirect landing URL containing ?code=...
 # @stdout                 Raw code value
 # @exit    0              Code found
 # @exit    1              No code parameter present
 ##
ebay_user_token::_extract_code() {
  local url="$1"
  local code="${url##*[?&]code=}"

  if [[ "${code}" == "${url}" ]]; then
    return 1
  fi

  echo "${code%%&*}"
}

#@/command
 # Mint a new eBay user refresh token and write it back to 1Password.
 #
 # @env     TF_VAR_ebay_client_id      eBay App ID (from .env op:// ref)
 # @env     TF_VAR_ebay_client_secret  eBay Cert ID (from .env op:// ref)
 # @env     EBAY_RUNAME               RuName (OAuth redirect_uri value)
 # @env     EBAY_SIGNIN_URL           Portal-generated branded consent URL
 #
 # @stdin                  Redirect landing URL pasted by the operator
 # @stdout                 Progress, token expiry, next steps
 # @stderr                 Error messages
 #
 # @exit    0              Token minted and written to 1Password
 # @exit    1              Missing deps/env, bad code, or exchange failure
 ##
ebay_user_token() {
  ebay_user_token::_check_deps curl jq op open || return 1

  local var
  for var in EBAY_CLIENT_ID EBAY_CLIENT_SECRET EBAY_RUNAME EBAY_SIGNIN_URL; do
    if [[ -z "${!var:-}" ]]; then
      ebay_user_token::_err \
        "${var} is not set (run via make maintenance/ebay-token)"
      return 1
    fi
  done

  echo "Opening the eBay consent page (sign in, then Agree and Continue):"
  echo "  ${EBAY_SIGNIN_URL}"
  open "${EBAY_SIGNIN_URL}"
  echo ""
  echo "After consenting you will land on the accepted URL with ?code=..."
  echo "The code is single-use and expires in ~5 minutes."
  read -r -p "Paste the full landing URL: " landing_url

  local code
  if ! code="$(ebay_user_token::_extract_code "${landing_url}")"; then
    ebay_user_token::_err "No code= parameter found in the pasted URL"
    return 1
  fi

  echo "Exchanging authorization code..."
  local response
  response="$(curl -sS -u "${EBAY_CLIENT_ID}:${EBAY_CLIENT_SECRET}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=${code}" \
    -d "redirect_uri=${EBAY_RUNAME}" \
    "${TOKEN_URL}")"

  local refresh_token
  refresh_token="$(jq -r '.refresh_token // empty' <<<"${response}")"
  if [[ -z "${refresh_token}" ]]; then
    ebay_user_token::_err "Exchange failed: $(jq -c 'del(.access_token)' \
      <<<"${response}" 2> /dev/null || echo "${response}")"
    return 1
  fi

  local expires_in expiry_date
  expires_in="$(jq -r '.refresh_token_expires_in // 47304000' <<<"${response}")"
  expiry_date="$(date -r "$(( $(date +%s) + expires_in ))" +%Y-%m-%d)"

  echo "Writing refresh token to op://${OP_VAULT}/${OP_ITEM}/${OP_FIELD}..."
  op item edit "${OP_ITEM}" --vault "${OP_VAULT}" \
    "${OP_FIELD}=${refresh_token}" > /dev/null

  # Best-effort: keep the item's expiry field honest so 1Password can
  # surface the deadline. Field layouts vary; a miss is not a failure.
  if ! op item edit "${OP_ITEM}" --vault "${OP_VAULT}" \
      "expires=${expiry_date}" > /dev/null 2>&1; then
    echo "note: could not set the item's expires field — set it by hand"
  fi

  echo ""
  echo "done: refresh token minted (expires ~${expiry_date})"
  echo "next: make apply && make deploy   # seed SSM, reconcile the host"
}

ebay_user_token "$@"
