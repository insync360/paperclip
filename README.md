# Paperclip on Google Cloud

Deployment scripts for self-hosting [Paperclip](https://paperclip.ing) ([source](https://github.com/paperclipai/paperclip)), the open-source AI agent orchestration app, on GCP.

## Architecture

```
            DNS A record
                 │
        ┌────────▼─────────┐  static external IP, firewall 80/443 (SSH via IAP only)
        │ Compute Engine VM │  Debian 12, e2-standard-4
        │  docker compose:  │
        │   caddy :443 ─────┼─► paperclip :3100 (ghcr.io/paperclipai/paperclip)
        │   cloudsql-proxy ◄┼── DATABASE_URL
        └──┬──────────┬─────┘
           │          │
  pd-balanced data    Cloud SQL Postgres 17 (daily backups + PITR)
  disk /paperclip     Secret Manager (auth, signing, master key, API keys)
  (daily snapshots)
```

Why a VM rather than Cloud Run: Paperclip is a long-running, stateful server. It runs a heartbeat scheduler, spawns agent CLIs (Claude Code, Codex, Gemini, …) as child processes, and keeps workspaces and instance config on a local filesystem at `/paperclip`. Cloud Run scales to zero, throttles CPU outside requests and has no persistent disk, so it fits poorly. A single VM with a persistent disk works like the upstream Docker/ECS setup.

## Prerequisites

- A GCP project with billing enabled, and `gcloud` installed and logged in (`gcloud auth login`) as a project Owner (or equivalent).
- A domain or subdomain whose DNS you control.
- `openssl` on your machine.

## Deploy

```bash
cp gcp/.env.example gcp/.env      # set GCP_PROJECT, GCP_REGION, GCP_ZONE, PAPERCLIP_DOMAIN
./gcp/deploy.sh
```

You can run the script again safely. It does the following:

1. Enables the Compute, Cloud SQL, Secret Manager, IAM and IAP APIs.
2. Creates the `paperclip-vm` service account with Cloud SQL client and logging/monitoring roles.
3. Generates the `paperclip-db-password`, `paperclip-auth-secret`, `paperclip-tool-action-signing-secret` and `paperclip-secrets-master-key` secrets in Secret Manager. It creates each one only once and never rotates it.
4. Creates Cloud SQL `paperclip-db` (Postgres 17 with backups, PITR and deletion protection), plus the `paperclip` database and user.
5. Reserves a static IP and adds firewall rules: 80/443 open to the internet, 22 open only to IAP.
6. Creates a 100 GB `paperclip-data` disk with a daily snapshot schedule kept for 14 days.
7. Creates or updates the VM. Its [startup script](gcp/startup.sh) installs Docker, mounts the data disk, reads secrets from Secret Manager, and starts [docker-compose.yml](gcp/docker-compose.yml).

Then:

1. **DNS**: create an `A` record for `PAPERCLIP_DOMAIN` pointing to the IP the script prints. Caddy gets a Let's Encrypt certificate automatically once the record resolves.
2. Open `https://PAPERCLIP_DOMAIN` and **sign up**. The first account becomes the instance admin.
3. **Turn off public sign-up**: `./gcp/deploy.sh disable-signup`. Add more people with Paperclip's invite flow.
4. **Add model provider keys** (optional; you can also set them per agent in the UI):
   ```bash
   ./gcp/deploy.sh set-secret anthropic-api-key   # prompts for the value
   ./gcp/deploy.sh set-secret openai-api-key
   ./gcp/deploy.sh set-secret github-token
   ```

## Operations

| Task | Command |
|---|---|
| Tail logs | `./gcp/deploy.sh logs` |
| SSH | `./gcp/deploy.sh ssh` |
| Upgrade Paperclip | `./gcp/deploy.sh restart` (pulls the image tag again; migrations run automatically) |
| Pin a version | set `PAPERCLIP_IMAGE=ghcr.io/paperclipai/paperclip@sha256:…` in `gcp/.env`, then `./gcp/deploy.sh` |
| Change config/compose | edit files under `gcp/`, then `./gcp/deploy.sh` |
| Health check | `curl -sf https://$PAPERCLIP_DOMAIN/api/health` |

Pinning a digest is recommended for production. `latest` follows upstream stable releases.

## Sizing and cost (approximate, us-central1)

| Resource | Default | ≈ USD/month |
|---|---|---|
| VM `e2-standard-4` (4 vCPU, 16 GB) | `VM_MACHINE_TYPE` | ~100 |
| Cloud SQL `db-custom-1-3840` | `SQL_TIER` | ~50 |
| Disks (50 GB boot + 100 GB data) + snapshots | `DATA_DISK_SIZE_GB` | ~20 |

Agent runs execute on the VM, so size the VM for how many agents run at the same time. `e2-standard-2` is enough for a trial.

## Tear down

Deletion protection and `auto-delete=no` on the data disk stop data from being lost by accident. To remove everything:

```bash
gcloud compute instances delete paperclip-vm --zone $GCP_ZONE
gcloud compute disks delete paperclip-data --zone $GCP_ZONE
gcloud sql instances patch paperclip-db --no-deletion-protection && gcloud sql instances delete paperclip-db
gcloud compute addresses delete paperclip-ip --region $GCP_REGION
gcloud compute firewall-rules delete paperclip-allow-web paperclip-allow-iap-ssh
gcloud compute resource-policies delete paperclip-daily --region $GCP_REGION
gcloud secrets list --filter='name~paperclip-' --format='value(name)' | xargs -n1 gcloud secrets delete
gcloud iam service-accounts delete paperclip-vm@$GCP_PROJECT.iam.gserviceaccount.com
```
