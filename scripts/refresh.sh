#!/usr/bin/env bash

#?/name     refresh.sh — Sync host secrets from SSM and reconcile compose
#?/synopsis refresh.sh
#?/description
 # Tracked literal script, delivered via the host's git checkout. Pulling
 # the checkout is the CALLER's job (make deploy and cloud-init both run
 # `git fetch && git reset --hard origin/main` first) — this script never
 # modifies the tree it executes from. Idempotent: run by cloud-init at
 # first boot and by `make deploy` after.
 ##

set -euo pipefail

REGION="${MCP_REGION:-us-west-1}"
PREFIX="${MCP_PREFIX:-common/mcp}"
APP_DIR="${MCP_APP_DIR:-/opt/mcp}"

cd "${APP_DIR}"

# --- Data directories (bind-mount targets on the EBS data volume) ------------
# +1 service with persistent data = +1 dir here (and its compose bind mount).
mkdir -p data/caddy data/caddy-config data/falkordb

# --- Secrets from SSM (SecureString) -> .env (root-only) ---------------------
# Env var name = last path segment, so every secret needs a unique basename.
# Written via tmp + mv so a concurrent reader never sees a partial file.
umask 077
: >.env.tmp
for name in $(aws ssm get-parameters-by-path --region "${REGION}" \
  --path "/${PREFIX}/secrets/" --recursive \
  --query "Parameters[].Name" --output text); do
  val="$(aws ssm get-parameter --region "${REGION}" --with-decryption \
    --name "${name}" --query Parameter.Value --output text)"
  # Compose interpolates $-sequences in project .env values; escape them
  # so secrets containing `$` survive verbatim.
  val="${val//\$/\$\$}"
  echo "${name##*/}=${val}" >>.env.tmp
done
mv .env.tmp .env
umask 022

# --- Reconcile ---------------------------------------------------------------
# --remove-orphans retires containers whose service was removed from compose.
# Compose recreates containers whose compose config (incl. interpolated .env
# values) changed; bind-mounted file contents are invisible to it, so Caddy is
# reloaded explicitly (zero-downtime Caddyfile/vhost pushes). Backends that
# read config at startup need a `docker compose restart <svc>` after a push.
docker compose up -d --build --remove-orphans
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
