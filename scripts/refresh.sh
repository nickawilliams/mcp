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
# Terraform owns this value (local.path_prefix): cloud-init templates it into
# user_data, and `make deploy` passes it from `terraform output -raw
# path_prefix`. The literal below is only a last-resort fallback for a manual
# run on the host, and will be stale the moment the stack's partition changes.
PREFIX="${MCP_PREFIX:-prod/mcp}"
APP_DIR="${MCP_APP_DIR:-/opt/mcp}"

cd "${APP_DIR}"

# --- Data directories (bind-mount targets on the EBS data volume) ------------
# +1 service with persistent data = +1 dir here (and its compose bind mount).
mkdir -p data/caddy data/caddy-config data/falkordb

# --- Secrets from SSM (SecureString) -> .env (root-only) ---------------------
# Env var name = last path segment, so every secret needs a unique basename.
# Written via tmp + mv so a concurrent reader never sees a partial file.

# Listed in its own assignment rather than inline in the `for`, for two
# reasons. `set -e` ignores a failed command substitution in a `for` word
# list but honours one in an assignment, so an API or IAM failure aborts
# here instead of yielding an empty list. And an empty list is itself
# indistinguishable from that failure, so it is rejected below: writing an
# empty .env would strip every secret from the stack on the next reconcile,
# quietly, and the usual cause is a PREFIX that no longer matches where
# terraform put the parameters.
names="$(aws ssm get-parameters-by-path --region "${REGION}" \
  --path "/${PREFIX}/secrets/" --recursive \
  --query "Parameters[].Name" --output text)"

if [[ -z "${names}" || "${names}" == "None" ]]; then
  echo "refresh.sh: no parameters under /${PREFIX}/secrets/" >&2
  echo "refresh.sh: refusing to write an empty .env" >&2
  echo "refresh.sh: check MCP_PREFIX (is '${PREFIX}') and the host role" >&2
  exit 1
fi

umask 077
: >.env.tmp
for name in ${names}; do
  val="$(aws ssm get-parameter --region "${REGION}" --with-decryption \
    --name "${name}" --query Parameter.Value --output text)"
  # Compose interpolates $-sequences in project .env values; escape them
  # so secrets containing `$` survive verbatim.
  val="${val//\$/\$\$}"
  echo "${name##*/}=${val}" >>.env.tmp
done
mv .env.tmp .env
umask 022

echo "refresh.sh: wrote $(wc -l <.env | tr -d ' ') secrets from /${PREFIX}/secrets/"

# --- Reconcile ---------------------------------------------------------------
# --remove-orphans retires containers whose service was removed from compose.
# Compose recreates containers whose compose config (incl. interpolated .env
# values) changed; bind-mounted file contents are invisible to it, so Caddy is
# reloaded explicitly (zero-downtime Caddyfile/vhost pushes). Backends that
# read config at startup need a `docker compose restart <svc>` after a push.
docker compose up -d --build --remove-orphans
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
