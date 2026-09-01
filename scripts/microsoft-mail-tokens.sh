#!/usr/bin/env bash

#?/name     microsoft-mail-tokens.sh — Mint the Microsoft mail refresh tokens
#?/synopsis microsoft-mail-tokens.sh
#?/description
 # The mail service's 'microsoft' account (Live.com personal) cannot use a
 # password: Microsoft retired basic auth — app passwords included — for
 # personal accounts in September 2024, and blocks SMTP AUTH outright. The
 # account instead runs on two OAuth2 refresh tokens with disjoint scopes:
 # IMAP reading (outlook.office.com XOAUTH2) and Graph API sending
 # (graph.microsoft.com Mail.Send). Microsoft refuses to issue one token
 # spanning both hosts, so the device-code sign-in runs twice.
 #
 # This script drives both device-code flows against the consumers tenant
 # and writes the resulting refresh tokens back to the 1Password item the
 # .env op:// refs point at (creating the item on first run), from where
 # terraform lands them in SSM. MSA refresh tokens live ~90 days; when
 # IMAP or Graph starts failing with auth errors, re-run this, then
 # `make apply && make deploy`.
 #
 # The client id is Thunderbird's public registration (recommended by
 # mail-mcp's setup guide) — a public client, no secret involved. Run via
 # `make maintenance/microsoft-tokens`; the write-back uses the shell `op`
 # (desktop-app auth). macOS only (BSD date, `open`).
 ##

set -euo pipefail

readonly CLIENT_ID="9e5f94bc-e8a4-4e73-b8be-63364c29d753"
readonly AUTH_BASE="https://login.microsoftonline.com/consumers/oauth2/v2.0"
readonly SCOPE_IMAP="https://outlook.office.com/IMAP.AccessAsUser.All offline_access"
readonly SCOPE_GRAPH="https://graph.microsoft.com/Mail.Send offline_access"
readonly OP_VAULT="Infrastructure"
readonly OP_ITEM="email-oauth-microsoft"
readonly ACCOUNT="nickawilliams@live.com"

#@/private
 # Log an error message to STDERR.
 #
 # @operand <message...>   Error message text
 # @stderr                 Timestamped error message
 ##
microsoft_mail_tokens::_err() {
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
microsoft_mail_tokens::_check_deps() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" &> /dev/null; then
      microsoft_mail_tokens::_err "Required command not found: ${cmd}"
      return 1
    fi
  done
}

#@/private
 # Run one device-code flow and print the resulting refresh token.
 # Progress goes to STDERR so the token can be command-substituted.
 #
 # @operand <label>        Human-readable name for this token (progress text)
 # @operand <scope>        OAuth scope string to request
 #
 # @stdout                 The refresh token
 # @stderr                 Sign-in instructions and progress
 #
 # @exit    0              Token minted
 # @exit    1              Device-code request, sign-in, or exchange failure
 ##
microsoft_mail_tokens::_mint() {
  local label="$1"
  local scope="$2"

  local dc_response
  dc_response="$(curl -sS \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "scope=${scope}" \
    "${AUTH_BASE}/devicecode")"

  local device_code
  device_code="$(jq -r '.device_code // empty' <<<"${dc_response}")"
  if [[ -z "${device_code}" ]]; then
    microsoft_mail_tokens::_err \
      "Device-code request failed (${label}): ${dc_response}"
    return 1
  fi

  local verification_uri user_code interval expires_in
  verification_uri="$(jq -r '.verification_uri' <<<"${dc_response}")"
  user_code="$(jq -r '.user_code' <<<"${dc_response}")"
  interval="$(jq -r '.interval // 5' <<<"${dc_response}")"
  expires_in="$(jq -r '.expires_in // 900' <<<"${dc_response}")"

  # Convenience on macOS: the code lands in the clipboard, ready to paste
  # into the sign-in page. Elsewhere pbcopy is absent and the code is
  # simply typed from the terminal.
  local code_hint=""
  if command -v pbcopy &> /dev/null; then
    printf '%s' "${user_code}" | pbcopy && code_hint=" (copied to clipboard)"
  fi

  {
    echo ""
    echo "=== ${label} ==="
    echo "Sign in as ${ACCOUNT} at: ${verification_uri}"
    echo "Enter code: ${user_code}${code_hint}"
    echo "(waiting for sign-in, up to $(( expires_in / 60 )) minutes...)"
  } >&2
  open "${verification_uri}"

  local deadline=$(( $(date +%s) + expires_in ))
  local token_response error
  while (( $(date +%s) < deadline )); do
    sleep "${interval}"
    token_response="$(curl -sS \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "client_id=${CLIENT_ID}" \
      --data-urlencode "device_code=${device_code}" \
      "${AUTH_BASE}/token")"

    if [[ -n "$(jq -r '.refresh_token // empty' <<<"${token_response}")" ]]; then
      echo "${label}: token minted" >&2
      jq -r '.refresh_token' <<<"${token_response}"
      return 0
    fi

    error="$(jq -r '.error // empty' <<<"${token_response}")"
    case "${error}" in
      authorization_pending) ;;
      slow_down) (( interval += 5 )) ;;
      *)
        microsoft_mail_tokens::_err "Sign-in failed (${label}): $(
          jq -c 'del(.access_token)' <<<"${token_response}" 2> /dev/null \
            || echo "${token_response}")"
        return 1
        ;;
    esac
  done

  microsoft_mail_tokens::_err "Timed out waiting for sign-in (${label})"
  return 1
}

#@/command
 # Mint both Microsoft refresh tokens and write them to 1Password.
 #
 # @stdout                 Progress, next steps
 # @stderr                 Sign-in instructions, error messages
 #
 # @exit    0              Both tokens minted and written to 1Password
 # @exit    1              Missing deps, sign-in failure, or op write failure
 ##
microsoft_mail_tokens() {
  microsoft_mail_tokens::_check_deps curl jq op open || return 1

  echo "Two sign-ins follow — Microsoft will not span IMAP and Graph"
  echo "scopes with one token."

  local imap_token graph_token
  imap_token="$(microsoft_mail_tokens::_mint \
    "IMAP token (reading)" "${SCOPE_IMAP}")" || return 1
  graph_token="$(microsoft_mail_tokens::_mint \
    "Graph token (sending)" "${SCOPE_GRAPH}")" || return 1

  echo ""
  echo "Writing tokens to op://${OP_VAULT}/${OP_ITEM}..."
  if ! op item get "${OP_ITEM}" --vault "${OP_VAULT}" &> /dev/null; then
    op item create --category "API Credential" --vault "${OP_VAULT}" \
      --title "${OP_ITEM}" "username=${ACCOUNT}" > /dev/null
  fi
  op item edit "${OP_ITEM}" --vault "${OP_VAULT}" \
    "imap-refresh-token[concealed]=${imap_token}" \
    "graph-refresh-token[concealed]=${graph_token}" > /dev/null

  # Best-effort: keep the item's expiry field honest so 1Password can
  # surface the ~90-day MSA deadline. A miss is not a failure.
  local expiry_date
  expiry_date="$(date -v+90d +%Y-%m-%d)"
  if ! op item edit "${OP_ITEM}" --vault "${OP_VAULT}" \
      "expires=${expiry_date}" > /dev/null 2>&1; then
    echo "note: could not set the item's expires field — set it by hand"
  fi

  echo ""
  echo "done: both refresh tokens minted (expire ~${expiry_date})"
  echo "next: make apply && make deploy   # seed SSM, reconcile the host"
}

microsoft_mail_tokens "$@"
