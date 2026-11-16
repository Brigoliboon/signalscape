# Operations runbook

Day-to-day operation of the production server: logs, restarts, backups, rollback, rotating keys, a site-down checklist and reprocessing surveys. Server facts (paths, container names, service names) were checked on 2026-11-16; see [DEPLOYMENT.md](DEPLOYMENT.md) for the full picture.

Every command below that is marked **(tested)** was run on 2026-11-16, either read-only on the server or against a throwaway local database. Commands marked **(recommended, not run on production)** are suggestions that were not executed against the real server.

All server commands assume you are logged in over SSH (see [DEPLOYMENT.md](DEPLOYMENT.md)) and are in the Compose project folder:

```bash
cd /home/ubuntu/actions-runner-signalscape/_work/signalscape/signalscape/api
```

Never `cat` the `.env` file in that folder, and never paste its content anywhere.

## Quick reference

| I want to | Command |
|---|---|
| See what is running | `docker compose --profile prod ps` **(tested)** |
| API logs | `docker compose --profile prod logs --tail 200 api` |
| Follow logs live | `docker compose --profile prod logs -f api` |
| Restart the API only | `docker compose --profile prod restart api` |
| Check health from the server | `curl -fsS http://127.0.0.1:8000/api/health` |
| Check health from outside | `curl -fsS https://signalscape.boonbrigoli.site/api/health` **(tested)** |
| Open a database shell | `docker compose --profile prod exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` |
| Runner status | `systemctl status actions.runner.Brigoliboon-signalscape.signalscape-vm.service` |

`--profile prod` is needed so Compose also sees the `caddy` service.

## Logs

- **API:** `docker compose --profile prod logs --tail 200 api` (or `docker logs signalscape-api-1`). It is uvicorn's output (requests and errors). Migration output from the start-up `alembic upgrade head` is at the top after a restart.
- **Database:** `docker compose --profile prod logs --tail 100 db`.
- **Caddy:** `docker compose --profile prod logs --tail 100 caddy`. It logs certificate issuance and renewal (ACME). **(tested: renewal entries for `signalscape.boonbrigoli.site` were present)**
- **Deploy runs:** on GitHub under Actions, workflow CD. On the VM, `journalctl -u actions.runner.Brigoliboon-signalscape.signalscape-vm.service -n 50 --no-pager` shows which jobs the runner started and their results **(tested)**; the runner's detailed logs are under `/home/ubuntu/actions-runner-signalscape/_diag/`.
- Docker keeps container logs on disk with the default json-file driver and no size limit set in `docker-compose.yml`. If the disk fills (`df -h /`), that is one place to look.

## Restart and stop

```bash
docker compose --profile prod restart api        # restarts the API (also reruns migrations on start)
docker compose --profile prod restart            # everything
docker compose --profile prod up -d              # (re)create anything that is missing
docker compose --profile prod stop api           # stop the API only; Caddy then answers 502 for /api/*
```

All three containers have `restart: unless-stopped`, so they come back after a server reboot as long as the Docker service starts. The runner service is `enabled` and starts on boot too.

Do not run `docker compose down -v`: `-v` deletes the volumes, including the database.

## Backups and restore

**Current state: no backup was found.** On 2026-11-16 there was no crontab for the `ubuntu` user, nothing for SignalScape in `/etc/cron.d`, and nothing in `/var/backups`. (Only those places were checked; the rest of the server was not searched, and the repo has no backup job.) Everything (surveys, readings, users) lives only in the Docker volume `signalscape_postgres_data`, floor plan images only in `signalscape_uploads_data`, and TLS certificates in `signalscape_caddy_data`. If the VM disk is lost, so is the data. The commands below are a **recommendation**.

### Back up the database (recommended, not run on production)

The commands below were run against a throwaway local Postgres 16 and produced a dump that restored with the right row counts. The `db` container already has `POSTGRES_USER` and `POSTGRES_DB` in its environment, so no secret appears on the command line.

```bash
mkdir -p ~/backups
docker compose --profile prod exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > ~/backups/signalscape-$(date +%F).dump
ls -lh ~/backups
```

`-Fc` is the compressed custom format. Copy the file off the server too (a dump on the same disk does not protect against disk loss), for example with `scp -i <key> ubuntu@signalscape.boonbrigoli.site:backups/<file> .`.

To run it daily, add to `crontab -e` for the `ubuntu` user (adjust the path, and keep only the last N files):

```cron
15 2 * * * cd /home/ubuntu/actions-runner-signalscape/_work/signalscape/signalscape/api && docker compose --profile prod exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > /home/ubuntu/backups/signalscape-$(date +\%F).dump
```

### Back up floor plans and certificates (recommended, not run on production)

```bash
docker run --rm -v signalscape_uploads_data:/data:ro -v ~/backups:/backup alpine \
  tar czf /backup/uploads-$(date +%F).tgz -C /data .
```

The certificates can be re-issued automatically, so `caddy_data` is optional to back up.

### Restore the database (recommended)

Practise this on a copy first. Local test of the dump and restore round trip: **(tested locally, custom format, into an empty database)**.

1. Stop the API so nothing writes during the restore: `docker compose --profile prod stop api`.
2. Restore into an empty database. The safest way is a new database next to the old one, then check it:

   ```bash
   docker compose --profile prod exec -T db sh -c 'createdb -U "$POSTGRES_USER" signalscape_restore'
   docker compose --profile prod exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d signalscape_restore --no-owner' \
     < ~/backups/signalscape-<date>.dump
   docker compose --profile prod exec db sh -c 'psql -U "$POSTGRES_USER" -d signalscape_restore -c "select count(*) from surveys"'
   ```

3. To make the restored data live, either point the API at the new database (change `POSTGRES_DB` for the stack, a bigger change), or swap names inside Postgres:

   ```sql
   -- in psql connected to the "postgres" database, with nobody connected to the two databases
   ALTER DATABASE signalscape RENAME TO signalscape_old;
   ALTER DATABASE signalscape_restore RENAME TO signalscape;
   ```

4. Start the API again: `docker compose --profile prod start api`, then check `/api/health`.

Restoring over the live database with `pg_restore --clean --if-exists` also works in principle but was not tested; prefer the side-by-side way.

## Rolling back a bad deploy

Every deploy pushes an image tagged with the commit SHA, and the VM keeps the images of earlier deploys locally (16 older tags besides the running one were present on 2026-11-16, so a rollback does not need to download anything).

1. Find the SHA of the last good version: the commit of the last good merge on GitHub, or `docker images --format '{{.Tag}} {{.CreatedSince}}' ghcr.io/brigoliboon/signalscape/api` on the VM **(tested)**.
2. Point the stack at it by changing only the `API_IMAGE` line, without printing the file:

   ```bash
   sed -i 's|^API_IMAGE=.*|API_IMAGE=ghcr.io/brigoliboon/signalscape/api:<good-sha>|' .env
   docker compose --profile prod up -d
   curl -fsS https://signalscape.boonbrigoli.site/api/health
   ```

3. Then fix `main` properly (revert the bad PR). The next deploy overwrites `.env` and moves the stack forward again, so the rollback holds only until the next merge to `main`.

Database caution: the API runs `alembic upgrade head` on start and the older image does not undo migrations. After a rollback the database keeps the newer schema. That is fine for additive changes (a new nullable column). If a migration changed or removed something the old code needs, restore a dump taken before the deploy instead (see above), which is another reason to take backups.

## Rotating keys and secrets

After any change to a GitHub secret, run the CD workflow (Actions, CD, Run workflow on `main`) or merge a PR so the server `.env` is rewritten. Names are in [CONFIG_AND_SECRETS.md](CONFIG_AND_SECRETS.md). Set secrets without leaving values in shell history, with `gh secret set <NAME>` (it prompts) or the GitHub web page.

- **`JWT_SECRET`:** set the new random value in GitHub and redeploy. Effect: every issued token stops working, so everyone must sign in again. Nothing else changes.
- **`POSTGRES_PASSWORD`:** be careful. Postgres only reads this variable when it first creates its data directory, so changing the secret alone makes the API unable to log in to the existing database. Order matters: (1) change the role's password inside Postgres: `docker compose --profile prod exec db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'` then `\password signalscape` at the prompt; (2) immediately update the GitHub secret and redeploy. The API is down between the two steps. **(recommended, not run on production)**
- **`MAPBOX_TOKEN`:** create a new public token in the Mapbox account, update the secret, and let CI rebuild the APK (any change under `app/` or a manual CI run). Old APKs keep the old token, so revoke the old token only after phones have the new app.
- **SSH key:** create a new key pair on your machine (`ssh-keygen -t ed25519`), append the new **public** key to `/home/ubuntu/.ssh/authorized_keys` on the VM, open a **second** terminal and confirm you can log in with the new key, then delete the old key's line. Keep the private key outside the repo, mode 600.
- **Runner registration:** on the VM, in the runner folder: `sudo ./svc.sh stop`, `./config.sh remove --token <REMOVAL_TOKEN>` (from GitHub's runner page), then register again with a new token and `sudo ./svc.sh install ubuntu && sudo ./svc.sh start` as in [DEPLOYMENT.md](DEPLOYMENT.md).
- **GitHub token for the registry:** nothing to rotate; `GITHUB_TOKEN` is created for each run.
- **If a secret leaked** (for example pasted into chat or committed): rotate it right away using the steps above. Removing it from a commit is not enough, because the repository is public and history is copied quickly.

## Site down checklist

Work from the outside in. Stop when you find the cause.

1. **Is it down for everyone?** From another network: `curl -sS -m 15 -I https://signalscape.boonbrigoli.site/api/health`.
2. **DNS:** `dig +short signalscape.boonbrigoli.site` should return the VM's IP. If it returns nothing, the A record is missing or the DNS provider has a problem.
3. **Can you reach the server?** `ssh -i <key> ubuntu@signalscape.boonbrigoli.site`. If not, check the VM in the cloud console (powered on? firewall rules for ports 22, 80, 443?).
4. **Containers:** `docker compose --profile prod ps`. All three should be `running`, with `api` and `db` `healthy`. If one is missing: `docker compose --profile prod up -d`. If it restarts in a loop, read its logs.
5. **API:** `curl -fsS http://127.0.0.1:8000/api/health` on the server.
   - Works, but the public URL fails: the fault is in Caddy, DNS or the firewall. Read `logs caddy`.
   - Returns 503 `database unavailable`: the `db` container is down or unhealthy, or the password does not match (after a password rotation). Read `logs db` and `logs api`.
   - Refuses the connection: the API container is not running or crashed on start. A failed migration shows at the top of `logs api`.
6. **TLS errors in the browser:** `docker compose --profile prod logs caddy | grep -i -E "error|obtain|acme"`. Certificates renew on their own; ports 80 and 443 must be open, and `SITE_ADDRESS` must be the real hostname.
7. **Disk full:** `df -h /` and `docker system df`. Old images are the usual cause; `docker image prune` removes unused ones (this deletes the local rollback images; the commit-tagged images stay available on GitHub's registry).
8. **A deploy just ran:** check the CD run on GitHub. If the smoke test failed, the previous containers may already have been replaced, so roll back as above.
9. **Deploys are stuck:** the runner service (`systemctl status actions.runner...`) may be down; restart it. See [DEPLOYMENT.md](DEPLOYMENT.md).

After the fix, confirm `/api/health` and `/api/docs` through the public URL, as the smoke test does.

## Reprocessing surveys

Processing results (coverage grids, access point estimates) are stored when a survey is processed. If the processing code changes (for example a new radius or a new column), surveys processed earlier keep their old results until they are processed again. Reprocessing replaces the stored results from the same readings; it does not touch the readings.

One survey (the survey must be `completed` or already `processed`):

```bash
curl -fsS -X POST -H "Authorization: Bearer $TOKEN" \
  https://signalscape.boonbrigoli.site/api/surveys/<survey-id>/process
```

You can also use **Process now** on the 2D map screen of a survey in the app. Roles allowed: Admin and Surveyor (Viewers get 403). A Surveyor can process only their own surveys; an Admin can process all.

All processed surveys that the token can see (use an Admin token to cover every survey). **(tested against a throwaway local API)**

```bash
#!/usr/bin/env bash
# API=https://signalscape.boonbrigoli.site TOKEN=<jwt> ./reprocess.sh
set -euo pipefail
page=1
while :; do
  body=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$API/api/surveys?status=processed&page=$page&page_size=100")
  ids=$(printf '%s' "$body" | python3 -c 'import sys,json; print("\n".join(i["id"] for i in json.load(sys.stdin)["items"]))')
  [ -z "$ids" ] && break
  for id in $ids; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" "$API/api/surveys/$id/process")
    echo "$id -> HTTP $code"
  done
  page=$((page+1))
done
```

Get a token as shown in [API_GUIDE.md](API_GUIDE.md) (it lasts 24 hours). Do not paste the token into chat or commit it.

## Creating or promoting an admin

See [DEPLOYMENT.md](DEPLOYMENT.md), section "Creating the first admin (CLI)". Admins can also change other users' role or active flag through `PATCH /api/users/{id}` and list users through `GET /api/users`.

## Not verified

- Backups, restore into the live database, the password rotation procedure, the SSH and runner rotation steps, and `docker image prune` were not run on the production server.
- The docker `json-file` log driver defaults were assumed from Docker's defaults; the daemon configuration on the VM was not read.
