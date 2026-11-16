# Local development setup

How to run the API, the database, the Flutter app and all the tests on a developer machine. The commands match what CI runs (`.github/workflows/ci.yml`); the ones marked as run were run on 2026-11-16 on a Linux laptop.

Related: [CONFIG_AND_SECRETS.md](CONFIG_AND_SECRETS.md) for every variable, [CI_CD.md](CI_CD.md) for what runs in CI, [API_GUIDE.md](API_GUIDE.md) for calling the API.

## What you need

| Tool | Version | Why |
|---|---|---|
| Python | 3.12 (`requires-python >= 3.12`; CI uses 3.12) | the API |
| PostgreSQL | 16 (CI and Compose use `postgres:16`) | the database |
| Docker with Compose v2 | any recent | optional: run the API and database as containers |
| Flutter | 3.41.6 stable (Dart 3.11.4); the same version CI pins | the app |
| Android phone | Android 7.0 or newer (`minSdk` is at least 24) | Wi-Fi scanning does not work in the emulator |
| Node.js | 18 or newer | only for the viewer's JavaScript tests |
| Java 17 | Temurin 17 in CI | only if you build an APK locally (CI builds the release APK, see [CI_CD.md](CI_CD.md)) |

Clone the repo and keep to the layout: `api/` (backend), `app/` (Flutter), `docs/`.

## API

### Option A: Docker Compose (database and API together)

```bash
cd api
cp .env.example .env        # then change the values; .env is git-ignored
docker compose up -d        # builds the API image and starts db and api
curl http://localhost:8000/api/health     # {"status":"ok"}
```

- API docs: http://localhost:8000/api/docs
- The `api` service publishes port 8000 on `127.0.0.1` only (`API_PORT` changes the host port). The database is **not** published to the host.
- The container runs `alembic upgrade head` on start, so the schema is created for you.
- Caddy is in the `prod` profile and does not start with a plain `docker compose up`. To try it locally: `docker compose --profile prod up -d` (it serves on port 80 because `SITE_ADDRESS` defaults to `:80`).
- Stop with `docker compose down` (add `-v` only if you want to delete the local database and uploads volumes).

### Option B: API on the host, Postgres separately

This is the setup for tests and quick edits.

1. Create a virtual environment and install the dependencies:

   ```bash
   cd api
   python3.12 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements-dev.txt     # includes requirements.txt, pytest, pytest-cov, httpx, ruff, pip-audit
   ```

2. Start a PostgreSQL 16 server and create two databases: one to run the API against, one for the tests (see the warning below). With Docker that is:

   ```bash
   docker run -d --name signalscape-pg -p 5432:5432 \
     -e POSTGRES_USER=signalscape -e POSTGRES_PASSWORD=signalscape \
     -e POSTGRES_DB=signalscape postgres:16-alpine
   docker exec signalscape-pg createdb -U signalscape signalscape_test
   ```

   (A native Postgres install works the same; use `createdb`.)

3. Set the connection and a JWT secret. The built-in default connection is `postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape`, which matches the container above. Settings are read from the environment or from `api/.env` (see [CONFIG_AND_SECRETS.md](CONFIG_AND_SECRETS.md)):

   ```bash
   export DATABASE_URL=postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape
   export JWT_SECRET=dev-only-secret
   ```

4. Apply the migrations and run the API:

   ```bash
   alembic upgrade head
   uvicorn app.main:app --reload            # http://127.0.0.1:8000/api/docs
   ```

5. Create an admin if you need one (the password comes from `SIGNALSCAPE_ADMIN_PASSWORD`, or is prompted for):

   ```bash
   python -m app.cli create-admin --email you@example.com --name "Your Name"
   ```

Schema changes always go through Alembic migrations in `api/alembic/versions/`. Create one with `alembic revision -m "what changed"`, fill in `upgrade()` and `downgrade()`, and run `alembic upgrade head`. Never edit the database by hand.

### API tests, coverage and lint

```bash
cd api
export DATABASE_URL=postgresql+psycopg://signalscape:signalscape@localhost:5432/signalscape_test
export JWT_SECRET=ci-test-secret
pytest                         # also reports coverage; fails under 60% (--cov-fail-under=60 in pyproject.toml)
ruff check .                   # lint
ruff format --check .          # formatting (ruff format . fixes it)
```

> **Use a separate test database.** `tests/conftest.py` runs `alembic upgrade head` against whatever `DATABASE_URL` points to and then runs each test inside a transaction that is rolled back. It does not drop data, but it does create the schema, so point it at `signalscape_test` the way CI does, not at a database you care about.

Details:

- `pytest` options are in `api/pyproject.toml`: tests are in `api/tests/`, and coverage is measured for `app/` and written to `coverage.xml` (git-ignored).
- The tests set `BCRYPT_ROUNDS=4` for speed. You do not have to set it.
- Show missing lines: coverage prints `term-missing` already. For one file: `pytest tests/test_results.py --no-cov`.
- `pip-audit -r requirements.txt` is the dependency scan CI runs in `api-audit`.

## The 3D viewer page and its JavaScript tests

The 3D page is plain static files in `api/app/static/viewer/` (Three.js is vendored, there is no build step). The API serves them at `/api/viewer/`; the app loads that URL with the survey id and a token in the URL fragment: `/api/viewer/#survey=<id>&token=<jwt>`. The Python tests in `tests/test_viewer.py` check the headers and that the page loads only its own files.

Pure helper functions have Node tests: `levels.mjs` (levels, confidence, projection) and `heat.mjs` (colour ramp, bilinear upsampling, contour lines, the tap lookup). From `api/`:

```bash
node --test tests/js/levels.test.mjs tests/js/heat.test.mjs
```

On Node 24, pass the file path as shown; passing only the folder fails. These tests are not part of CI, so run them when you change `levels.mjs` or `heat.mjs`. The same heatmap maths exists in Dart (`app/lib/core/heatmap.dart`, tested by `flutter test`); change both together.

## Flutter app

```bash
cd app
flutter pub get
flutter analyze
dart format --output=none --set-exit-if-changed .     # CI's format check; run `dart format .` to fix
flutter test                                          # unit and widget tests; no phone needed
```

`flutter test` uses `sqflite_common_ffi` for the offline queue tests, so they run on the host.

### Build-time settings (`--dart-define`)

| Define | Default | Meaning |
|---|---|---|
| `API_BASE_URL` | `https://signalscape.boonbrigoli.site` | Which API the app talks to |
| `MAPBOX_TOKEN` | empty | Public Mapbox token (starts with `pk.`). With it, the 2D map uses Mapbox satellite imagery with labels (style `satellite-streets-v12`). Empty falls back to OpenStreetMap tiles. |

Examples, with an Android phone connected over USB (`flutter devices` should list it):

```bash
# against the live server (the default)
flutter run --dart-define=MAPBOX_TOKEN=<your-public-token>

# against an API on your laptop (the phone and laptop must be on the same network)
flutter run --dart-define=API_BASE_URL=https://<host-the-phone-can-reach> \
            --dart-define=MAPBOX_TOKEN=<your-public-token>
```

For an Android emulator, `http://10.0.2.2:8000` reaches the host's port 8000 (that is the example in `app/lib/config.dart`). The emulator cannot scan Wi-Fi, so it is only good for the sign-in, buildings and map screens.

Keep the token out of the code and out of commits. CI passes the token from the GitHub secret `MAPBOX_TOKEN`.

### Building an APK

CI builds the release APK on every change under `app/` and uploads it as the artifact `app-release-apk` (see [CI_CD.md](CI_CD.md)). A local build needs the Android SDK and Java 17: `flutter build apk --release --dart-define=MAPBOX_TOKEN=<token>`. The output is `app/build/app/outputs/flutter-apk/app-release.apk`.

### Phone permissions

The app asks for location (needed by Android for Wi-Fi scans and the GPS start fix), nearby Wi-Fi devices and physical activity (step counting). See [USER_GUIDE.md](USER_GUIDE.md) for the screens.

## Handy checks before you push

```bash
# API
cd api && ruff check . && ruff format --check . && pytest
# App
cd app && flutter analyze && dart format --output=none --set-exit-if-changed . && flutter test
```

## Not verified

- Plain `http://` API URLs on a real phone: the Android manifest has no cleartext-traffic exception, so Android may block `http://` addresses in release builds. Use HTTPS (or the emulator address above in debug) unless you have tested otherwise.
- Node 18 and 20 were not run; the Node tests were run on Node 24.
