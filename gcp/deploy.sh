#!/usr/bin/env bash
# Provision and deploy Paperclip (https://paperclip.ing) on Google Cloud.
#
#   ./gcp/deploy.sh                  create/update everything and (re)start the app
#   ./gcp/deploy.sh set-secret NAME  store a secret from stdin (e.g. anthropic-api-key) and restart
#   ./gcp/deploy.sh disable-signup   turn off public sign-up once your admin account exists
#   ./gcp/deploy.sh restart          re-run the VM startup script (pulls the image, restarts)
#   ./gcp/deploy.sh logs             follow the Paperclip container logs
#   ./gcp/deploy.sh ssh              SSH to the VM over IAP
#
# Configuration comes from the environment or gcp/.env (see gcp/.env.example).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/.env" ]; then set -a; . "$HERE/.env"; set +a; fi

: "${GCP_PROJECT:?set GCP_PROJECT}"
GCP_REGION=${GCP_REGION:-us-central1}
GCP_ZONE=${GCP_ZONE:-${GCP_REGION}-a}
NAME=${NAME:-paperclip}
PAPERCLIP_IMAGE=${PAPERCLIP_IMAGE:-ghcr.io/paperclipai/paperclip:latest}
VM_MACHINE_TYPE=${VM_MACHINE_TYPE:-e2-standard-4}
BOOT_DISK_SIZE_GB=${BOOT_DISK_SIZE_GB:-50}
DATA_DISK_SIZE_GB=${DATA_DISK_SIZE_GB:-100}
SQL_TIER=${SQL_TIER:-db-custom-1-3840}
SQL_INSTANCE=${SQL_INSTANCE:-$NAME-db}
NETWORK=${NETWORK:-default}

VM=$NAME-vm
SA_EMAIL=$NAME-vm@$GCP_PROJECT.iam.gserviceaccount.com
TAG=$NAME-web
REQUIRED_SECRETS=(db-password auth-secret tool-action-signing-secret secrets-master-key)
OPTIONAL_SECRETS=(anthropic-api-key openai-api-key github-token)

g() { gcloud --project "$GCP_PROJECT" --quiet "$@"; }
log() { printf '\n==> %s\n' "$*"; }
exists() { "$@" >/dev/null 2>&1; }

grant_secret() {
  g secrets add-iam-policy-binding "$NAME-$1" \
    --member "serviceAccount:$SA_EMAIL" --role roles/secretmanager.secretAccessor >/dev/null
}

vm_run() {
  g compute ssh "$VM" --zone "$GCP_ZONE" --tunnel-through-iap --command "$1"
}

restart_app() {
  log "Re-running startup script on $VM"
  vm_run 'sudo google_metadata_script_runner startup'
}

cmd_deploy() {
  : "${PAPERCLIP_DOMAIN:?set PAPERCLIP_DOMAIN (e.g. paperclip.example.com)}"

  log "Enabling APIs"
  g services enable compute.googleapis.com sqladmin.googleapis.com \
    secretmanager.googleapis.com iam.googleapis.com iap.googleapis.com

  log "Service account $SA_EMAIL"
  if ! exists g iam service-accounts describe "$SA_EMAIL"; then
    g iam service-accounts create "$NAME-vm" --display-name "Paperclip VM"
    sleep 10  # let the new account propagate before binding roles
  fi
  for role in roles/cloudsql.client roles/logging.logWriter roles/monitoring.metricWriter; do
    g projects add-iam-policy-binding "$GCP_PROJECT" \
      --member "serviceAccount:$SA_EMAIL" --role "$role" --condition None >/dev/null
  done

  log "Secrets"
  for s in "${REQUIRED_SECRETS[@]}"; do
    if ! exists g secrets describe "$NAME-$s"; then
      if [ "$s" = db-password ]; then val=$(openssl rand -hex 24); else val=$(openssl rand -hex 32); fi
      printf '%s' "$val" | g secrets create "$NAME-$s" --replication-policy automatic --data-file=-
      echo "created $NAME-$s"
    fi
    grant_secret "$s"
  done
  for s in "${OPTIONAL_SECRETS[@]}"; do
    if exists g secrets describe "$NAME-$s"; then grant_secret "$s"; fi
  done

  log "Cloud SQL instance $SQL_INSTANCE (Postgres 17)"
  if ! exists g sql instances describe "$SQL_INSTANCE"; then
    g sql instances create "$SQL_INSTANCE" \
      --database-version POSTGRES_17 --edition enterprise --tier "$SQL_TIER" \
      --region "$GCP_REGION" --availability-type zonal \
      --storage-type SSD --storage-size 10 --storage-auto-increase \
      --backup-start-time 03:00 --enable-point-in-time-recovery \
      --retained-backups-count 14 --deletion-protection
  fi
  exists g sql databases describe paperclip --instance "$SQL_INSTANCE" \
    || g sql databases create paperclip --instance "$SQL_INSTANCE"
  db_password=$(g secrets versions access latest --secret "$NAME-db-password")
  if exists g sql users describe paperclip --instance "$SQL_INSTANCE"; then
    g sql users set-password paperclip --instance "$SQL_INSTANCE" --password "$db_password"
  else
    g sql users create paperclip --instance "$SQL_INSTANCE" --password "$db_password"
  fi
  sql_conn=$(g sql instances describe "$SQL_INSTANCE" --format 'value(connectionName)')

  log "Static IP"
  exists g compute addresses describe "$NAME-ip" --region "$GCP_REGION" \
    || g compute addresses create "$NAME-ip" --region "$GCP_REGION"
  ip=$(g compute addresses describe "$NAME-ip" --region "$GCP_REGION" --format 'value(address)')

  log "Firewall rules"
  exists g compute firewall-rules describe "$NAME-allow-web" \
    || g compute firewall-rules create "$NAME-allow-web" --network "$NETWORK" \
         --allow tcp:80,tcp:443,udp:443 --target-tags "$TAG" --source-ranges 0.0.0.0/0
  # SSH only through Identity-Aware Proxy.
  exists g compute firewall-rules describe "$NAME-allow-iap-ssh" \
    || g compute firewall-rules create "$NAME-allow-iap-ssh" --network "$NETWORK" \
         --allow tcp:22 --target-tags "$TAG" --source-ranges 35.235.240.0/20

  log "Data disk + daily snapshots"
  exists g compute resource-policies describe "$NAME-daily" --region "$GCP_REGION" \
    || g compute resource-policies create snapshot-schedule "$NAME-daily" --region "$GCP_REGION" \
         --daily-schedule --start-time 04:00 --max-retention-days 14 --on-source-disk-delete keep-auto-snapshots
  if ! exists g compute disks describe "$NAME-data" --zone "$GCP_ZONE"; then
    g compute disks create "$NAME-data" --zone "$GCP_ZONE" --type pd-balanced --size "${DATA_DISK_SIZE_GB}GB"
    g compute disks add-resource-policies "$NAME-data" --zone "$GCP_ZONE" --resource-policies "$NAME-daily"
  fi

  metadata="paperclip-domain=$PAPERCLIP_DOMAIN,paperclip-image=$PAPERCLIP_IMAGE,cloudsql-connection-name=$sql_conn,secret-prefix=$NAME"
  metadata_files="startup-script=$HERE/startup.sh,docker-compose=$HERE/docker-compose.yml,caddyfile=$HERE/Caddyfile"

  if exists g compute instances describe "$VM" --zone "$GCP_ZONE"; then
    log "Updating VM $VM"
    g compute instances add-metadata "$VM" --zone "$GCP_ZONE" \
      --metadata "$metadata" --metadata-from-file "$metadata_files"
    restart_app
  else
    log "Creating VM $VM"
    g compute instances create "$VM" --zone "$GCP_ZONE" \
      --machine-type "$VM_MACHINE_TYPE" \
      --image-family debian-12 --image-project debian-cloud \
      --boot-disk-size "${BOOT_DISK_SIZE_GB}GB" --boot-disk-type pd-balanced \
      --disk "name=$NAME-data,device-name=paperclip-data,mode=rw,auto-delete=no" \
      --address "$ip" --network "$NETWORK" --tags "$TAG" \
      --service-account "$SA_EMAIL" --scopes cloud-platform \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --metadata "$metadata,enable-oslogin=TRUE" --metadata-from-file "$metadata_files"
  fi

  cat <<MSG

Done.
  1. Point DNS:   $PAPERCLIP_DOMAIN  A  $ip
  2. Wait ~3 min for first boot, then open https://$PAPERCLIP_DOMAIN
     (Caddy obtains the TLS certificate once DNS resolves.)
  3. Sign up — the first account becomes the instance admin.
  4. Lock it down:  ./gcp/deploy.sh disable-signup
  5. Add model keys: ./gcp/deploy.sh set-secret anthropic-api-key   (value on stdin)
MSG
}

cmd_set_secret() {
  local s=${1:?usage: deploy.sh set-secret NAME   (value is read from stdin)} v
  if [ -t 0 ]; then read -rsp "Value for $NAME-$s: " v; echo; else v=$(cat); fi
  if exists g secrets describe "$NAME-$s"; then
    printf '%s' "$v" | g secrets versions add "$NAME-$s" --data-file=-
  else
    printf '%s' "$v" | g secrets create "$NAME-$s" --replication-policy automatic --data-file=-
  fi
  grant_secret "$s"
  restart_app
}

cmd_disable_signup() {
  g compute instances add-metadata "$VM" --zone "$GCP_ZONE" --metadata paperclip-disable-signup=true
  restart_app
}

case "${1:-deploy}" in
  deploy) cmd_deploy ;;
  set-secret) shift; cmd_set_secret "$@" ;;
  disable-signup) cmd_disable_signup ;;
  restart) restart_app ;;
  logs) vm_run 'cd /opt/paperclip && sudo docker compose logs -f --tail 200 paperclip' ;;
  ssh) g compute ssh "$VM" --zone "$GCP_ZONE" --tunnel-through-iap ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
