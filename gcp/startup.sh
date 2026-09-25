#!/bin/bash
# Compute Engine startup script for the Paperclip VM. Runs as root on every boot
# and is safe to re-run:  sudo google_metadata_script_runner startup
set -euo pipefail

APP_DIR=/opt/paperclip
DATA_MNT=/mnt/paperclip
DATA_DEV=/dev/disk/by-id/google-paperclip-data
MD=http://metadata.google.internal/computeMetadata/v1

md() { curl -fsS -H 'Metadata-Flavor: Google' "$MD/$1" 2>/dev/null || true; }
attr() { md "instance/attributes/$1"; }

PROJECT=$(md project/project-id)

# Reads the latest version of a Secret Manager secret using the VM's service
# account. Prints nothing when the secret is missing or not accessible.
secret() {
  local token
  token=$(md instance/service-accounts/default/token | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
  curl -fsS -H "Authorization: Bearer $token" \
    "https://secretmanager.googleapis.com/v1/projects/$PROJECT/secrets/$1/versions/latest:access" 2>/dev/null \
    | python3 -c 'import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)["payload"]["data"]).decode().strip())' 2>/dev/null \
    || true
}

require() {
  if [ -z "$2" ]; then echo "startup.sh: missing required value: $1" >&2; exit 1; fi
}

# --- Persistent data disk -------------------------------------------------------
if [ -e "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DATA_DEV"
  fi
  mkdir -p "$DATA_MNT"
  if ! grep -q " $DATA_MNT " /etc/fstab; then
    echo "UUID=$(blkid -s UUID -o value "$DATA_DEV") $DATA_MNT ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi
  mountpoint -q "$DATA_MNT" || mount "$DATA_MNT"
else
  echo "startup.sh: data disk $DATA_DEV not attached; using boot disk" >&2
  mkdir -p "$DATA_MNT"
fi
mkdir -p "$DATA_MNT/data" "$DATA_MNT/caddy/data" "$DATA_MNT/caddy/config"

# --- Docker Engine + Compose plugin ---------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release
  curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# --- App config -----------------------------------------------------------------
mkdir -p "$APP_DIR"
attr docker-compose > "$APP_DIR/docker-compose.yml"
attr caddyfile > "$APP_DIR/Caddyfile"

PAPERCLIP_DOMAIN=$(attr paperclip-domain)
PAPERCLIP_IMAGE=$(attr paperclip-image)
CLOUDSQL_CONNECTION_NAME=$(attr cloudsql-connection-name)
PAPERCLIP_AUTH_DISABLE_SIGN_UP=$(attr paperclip-disable-signup)
SECRET_PREFIX=$(attr secret-prefix)
SECRET_PREFIX=${SECRET_PREFIX:-paperclip}

DB_PASSWORD=$(secret "$SECRET_PREFIX-db-password")
BETTER_AUTH_SECRET=$(secret "$SECRET_PREFIX-auth-secret")
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$(secret "$SECRET_PREFIX-tool-action-signing-secret")
PAPERCLIP_SECRETS_MASTER_KEY=$(secret "$SECRET_PREFIX-secrets-master-key")

require paperclip-domain "$PAPERCLIP_DOMAIN"
require paperclip-image "$PAPERCLIP_IMAGE"
require cloudsql-connection-name "$CLOUDSQL_CONNECTION_NAME"
require "$SECRET_PREFIX-db-password" "$DB_PASSWORD"
require "$SECRET_PREFIX-auth-secret" "$BETTER_AUTH_SECRET"
require "$SECRET_PREFIX-tool-action-signing-secret" "$PAPERCLIP_TOOL_ACTION_SIGNING_SECRET"
require "$SECRET_PREFIX-secrets-master-key" "$PAPERCLIP_SECRETS_MASTER_KEY"

umask 077
cat > "$APP_DIR/.env" <<ENV
PAPERCLIP_DOMAIN=$PAPERCLIP_DOMAIN
PAPERCLIP_IMAGE=$PAPERCLIP_IMAGE
CLOUDSQL_CONNECTION_NAME=$CLOUDSQL_CONNECTION_NAME
PAPERCLIP_AUTH_DISABLE_SIGN_UP=${PAPERCLIP_AUTH_DISABLE_SIGN_UP:-false}
DB_PASSWORD=$DB_PASSWORD
BETTER_AUTH_SECRET=$BETTER_AUTH_SECRET
PAPERCLIP_TOOL_ACTION_SIGNING_SECRET=$PAPERCLIP_TOOL_ACTION_SIGNING_SECRET
PAPERCLIP_SECRETS_MASTER_KEY=$PAPERCLIP_SECRETS_MASTER_KEY
ANTHROPIC_API_KEY=$(secret "$SECRET_PREFIX-anthropic-api-key")
OPENAI_API_KEY=$(secret "$SECRET_PREFIX-openai-api-key")
GITHUB_TOKEN=$(secret "$SECRET_PREFIX-github-token")
ENV
umask 022

# --- Start ----------------------------------------------------------------------
cd "$APP_DIR"
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f >/dev/null || true
echo "startup.sh: Paperclip started for https://$PAPERCLIP_DOMAIN"
