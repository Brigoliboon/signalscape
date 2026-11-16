# Configuration and secrets

Every setting the project reads, where it is set, and its default. **Names only. No value of any secret is written here.** The list comes from `api/app/core/config.py`, `api/app/cli.py`, `api/docker-compose.yml`, `api/.env.example`, `app/lib/config.dart` and the two workflow files, and the GitHub secret names were read with `gh secret list` on 2026-11-16.

Related: [LOCAL_DEV.md](LOCAL_DEV.md), [DEPLOYMENT.md](DEPLOYMENT.md), [CI_CD.md](CI_CD.md), [RUNBOOK.md](RUNBOOK.md) (rotation).

## How settings flow

```mermaid
flowchart LR
    gs["GitHub Actions secrets"] -->|"deploy job writes"| env["api/.env on the VM<br/>(mode 600)"]
    env -->|"Compose substitution"| ctn["db and api containers<br/>environment"]
    ctn --> app["API settings<br/>(app/core/config.py)"]
    dev["api/.env on a laptop<br/>(git-ignored)"] --> app
    gs2["GitHub secret MAPBOX_TOKEN"] -->|"--dart-define at APK build"| apk["Release APK"]
```

Rules: secrets are never committed (`.env`, `.env.local` and `*.pem` are in `.gitignore`; CI runs Gitleaks on every PR, config `.gitleaks.toml`). `api/.env.example` holds placeholders only and is allowed by the Gitleaks config. Keep `.env.example` in step with this document.

## API settings (read by the application)

Defined as fields of the `Settings` class (pydantic-settings). A setting is read from an environment variable of the same name (case-insensitive) or from a `.env` file in the folder the API starts in (`api/` locally). Unknown names in `.env` are ignored, which is why the `POSTGRES_*` lines can sit in the same file.

| Variable | Default | Purpose | Notes |
|---|---|---|---|
| `DATABASE_URL` | `postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape` | SQLAlchemy connection string, also used by Alembic | In Compose it is built from the `POSTGRES_*` values and points at host `db`. Contains the DB password, so treat as secret. |
| `JWT_SECRET` | `change-me` | Key that signs login tokens | **Must be a long random value in production.** Changing it logs everybody out. Secret. |
| `JWT_ALGORITHM` | `HS256` | JWT signing algorithm | Not set anywhere in the deployment; the default is used. |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `1440` (24 hours) | Token lifetime; the login response's `expires_in` is this in seconds (86400) | Not set in deployment. |
| `BCRYPT_ROUNDS` | `12` (allowed 4 to 15) | Password hashing cost | The tests set it to `4` in `tests/conftest.py` for speed. |
| `UPLOADS_DIR` | `/data/uploads` | Where floor plan images are stored | In Compose this path is the `uploads_data` volume. |
| `APP_NAME` | `SignalScape API` | Title shown in the OpenAPI docs | Not set in deployment. |

## Docker Compose variables (`api/docker-compose.yml`)

Compose reads these from the shell or from `api/.env` next to the compose file.

| Variable | Default in the compose file | Purpose |
|---|---|---|
| `POSTGRES_USER` | `signalscape` | Database user, for the `db` and `api` services |
| `POSTGRES_PASSWORD` | `signalscape` | Database password. Secret in production. |
| `POSTGRES_DB` | `signalscape` | Database name |
| `JWT_SECRET` | `change-me` | Passed to the API container as `JWT_SECRET` |
| `API_IMAGE` | `signalscape-api:local` | Image name and tag for the `api` service. The deploy job sets it to `ghcr.io/<owner>/<repo>/api:<commit sha>`. |
| `API_PORT` | `8000` | Host port on `127.0.0.1` that maps to the API's port 8000 |
| `SITE_ADDRESS` | `:80` | What Caddy serves. Production uses the hostname, which makes Caddy use HTTPS. |

`DATABASE_URL` for the API container is assembled inside the compose file from the `POSTGRES_*` values. The defaults are for local use only.

## Command line tool

| Variable | Default | Purpose |
|---|---|---|
| `SIGNALSCAPE_ADMIN_PASSWORD` | none (prompted if unset) | Password for `python -m app.cli create-admin`. Prefer the prompt on shared machines. Secret. |

## Server `.env` (generated)

The deploy job writes `api/.env` on the VM on every run. Variable names in it: `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `JWT_SECRET`, `SITE_ADDRESS`, `API_IMAGE`. `POSTGRES_USER` and `POSTGRES_DB` are fixed in `cd.yml` (`signalscape`); the rest come from the secrets below. The server file's mode is 600.

## GitHub Actions secrets

Set in the repository under Settings, Secrets and variables, Actions. Names read with `gh secret list`:

| Secret | Used by | Purpose |
|---|---|---|
| `POSTGRES_PASSWORD` | CD `deploy` job | Written to the server `.env` as `POSTGRES_PASSWORD` |
| `JWT_SECRET` | CD `deploy` job | Written to the server `.env` as `JWT_SECRET` |
| `SITE_ADDRESS` | CD `deploy` job | Public hostname for Caddy (`signalscape.boonbrigoli.site`). A hostname is not secret, but it is stored as a secret. |
| `API_BASE_URL` | CD smoke test | Public base URL, with `https://` and no trailing slash, that the smoke test calls for `/api/health` and `/api/docs`. The job fails if it is empty. |
| `MAPBOX_TOKEN` | CI `app` job | Public Mapbox token baked into the release APK through `--dart-define=MAPBOX_TOKEN=...`. Empty means OpenStreetMap tiles. A `pk.` token ends up inside the APK, so restrict it in the Mapbox dashboard. |
| `GITHUB_TOKEN` (built in) | CD `publish` and `deploy` | Logs in to GitHub Container Registry. Created per run; nothing to configure. |

Repository **variables**: none are defined (`gh variable list` is empty).

The CI test jobs use fixed, non-secret values written in `ci.yml`: `DATABASE_URL=postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape_test` and `JWT_SECRET=ci-test-secret`, against a throwaway Postgres service container.

## Flutter build-time settings

Set with `--dart-define` when running or building the app (`app/lib/config.dart`). There is no runtime configuration file.

| Define | Default | Purpose |
|---|---|---|
| `API_BASE_URL` | `https://signalscape.boonbrigoli.site` | The API the app talks to |
| `MAPBOX_TOKEN` | empty | Public Mapbox token for the 2D satellite map; empty falls back to OpenStreetMap |

Fixed in code (change only by editing it): Mapbox style `satellite-streets-v12`, a start GPS accuracy limit of 10 m, and an upload batch size of 500 readings.

## Where each secret lives (summary)

| Item | Stored in | Also written to |
|---|---|---|
| Database password | GitHub secret `POSTGRES_PASSWORD` | server `api/.env`; inside the Postgres data volume as the role's password |
| JWT signing key | GitHub secret `JWT_SECRET` | server `api/.env` |
| Mapbox public token | GitHub secret `MAPBOX_TOKEN` | inside every release APK |
| Registry login | built-in `GITHUB_TOKEN` | the runner's Docker login for `ghcr.io` (stored by `docker login`) |
| Runner registration | GitHub (one-time token) | runner folder on the VM (its credential files; never copy them) |
| SSH private key | the developer's own machine, outside the repo | the matching public key is in `authorized_keys` on the VM |

## Not verified

- Whether any value is also stored in a password manager or elsewhere outside the repo and GitHub could not be checked.
- The `docker login ghcr.io` credential location on the VM was not inspected.
