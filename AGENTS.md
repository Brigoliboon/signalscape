# AGENTS.md: SignalScape

Rules for any coding agent (or person) working in this repo. Read this, `REQUIREMENTS.md` and `IMPLEMENTATION.md` before changing anything.

## Project in one line
SignalScape is a Flutter Android app plus a FastAPI REST API that maps a building's Wi-Fi coverage in 3D, built for ITSD 85 (Special Topics in Software Development).

## Source of truth
- `REQUIREMENTS.md`: what to build. Every feature has an id (FR-x, C-x, CI-x, CD-x).
- `IMPLEMENTATION.md`: the order to build it in, as weekly milestones M1 to M8 with checkboxes.
- If a task isn't in either file, stop and ask before building it. Don't add scope.

## Repo layout
- `api/`: FastAPI backend, Postgres, Docker, migrations, tests.
- `signalscape_mobile/`: Flutter Android app (includes the Three.js 3D view in a WebView).
- `.github/workflows/`: CI and CD.
- Don't create new top-level folders without asking.

## Stack (fixed; don't swap without approval)
- **App:** Flutter (Android only). Plugins for Wi-Fi scan, step counter, gyroscope/compass, barometer. 3D view uses Three.js in a WebView.
- **API:** Python 3.12, FastAPI, SQLAlchemy 2, Alembic, Pydantic v2, passlib with bcrypt, JWT, NumPy/SciPy.
- **Database:** PostgreSQL.
- **Tests:** pytest with pytest-cov (backend), `flutter test` (app).
- **Deploy:** Docker Compose with Caddy (HTTPS), GitHub Actions with a self-hosted runner on the server.
- Out of scope: cellular data, iOS, trained ML models (gap filling is interpolation math: IDW or kriging).

## Sequential workflow
Work strictly in milestone order. Don't start a milestone until the previous one is checked off, unless Boon says so.

1. **Pick** the first unchecked item in the current milestone of `IMPLEMENTATION.md`.
2. **Confirm** which requirement ids it covers. If it's unclear, ask before coding.
3. **Branch** off `main`: `feat/<milestone>-<short-name>` (e.g. `feat/m3-auth`). Fixes use `fix/...`, docs use `docs/...`.
4. **Build** the smallest change that completes the item.
5. **Test**: add or update tests in the same change. Run lint and tests locally before pushing.
6. **Pull request** into `main` with the template below. CI must pass. Never push straight to `main`.
7. **Update docs** in the same pull request: tick the checkbox in `IMPLEMENTATION.md` and add a dated line to its progress log. Update `REQUIREMENTS.md` only if a requirement changed and Boon approved it.
8. **Merge** after review. The merge redeploys automatically; check `/api/health` afterward.
9. Repeat with the next item.

### Pull request template
```
What: <one line>
Covers: <FR/C/CI/CD ids>, milestone <Mx>
Tests: <what was added or run>
Notes: <migrations, env vars, anything a reviewer must know>
```

### Commit messages
Conventional commits: `feat:`, `fix:`, `test:`, `docs:`, `ci:`, `chore:`, `refactor:`. Keep them short and present tense.

## API rules (course requirements, must hold for every endpoint)
- All routes under `/api`. OpenAPI docs at `/api/docs`. Health check at `/api/health` (no auth).
- Passwords hashed with bcrypt. Auth via JWT. At least 2 roles (Admin, Surveyor; Viewer optional), enforced on the server, not just hidden in the app.
- Validate every input with Pydantic models. Return clear 4xx errors.
- Every list endpoint supports pagination, filtering and sorting.
- Schema changes go through Alembic migrations only. Never edit the database by hand.
- The enabling technology (interpolation, access point estimation) is served through the API, not computed only in the app.

## App rules
- The app talks only to our own API. No direct database access, no third-party backend.
- Respect Android Wi-Fi scan throttling (about 4 scans per 2 minutes); don't fight it, design around it.
- Ask for location permission with a clear reason screen.
- At least 8 screens total (see `REQUIREMENTS.md`).

## Testing and CI
- CI runs on every push and pull request: lint, unit and integration tests (Postgres container), OpenAPI check, Docker build, dependency scan, `flutter analyze`, `flutter test`, APK build.
- **Backend line coverage must stay at 60% or more.** CI fails below that. Don't lower the threshold.
- A red CI blocks the merge. Fix it; don't skip or disable tests.

## Deployment
- Merges to `main` trigger the deploy job on the self-hosted runner: build the image, run migrations, restart with Docker Compose behind Caddy, then smoke test `/api/health`.
- The final release is tagged `v1.0`.

## Security and privacy (RA 10173)
- Never commit secrets. Use `.env` (git-ignored) locally and GitHub Actions secrets in CI. Keep `.env.example` up to date.
- Store only the data the feature needs. No personal data beyond account info; scan data is tied to buildings, not people.
- Follow the data privacy section of `REQUIREMENTS.md`.

## Don'ts
- Don't add features, libraries or services outside the stack without approval.
- Don't skip a milestone or work ahead of the current one.
- Don't rewrite or delete existing docs; update the relevant section.
- Don't merge without passing CI and a ticked checkbox in `IMPLEMENTATION.md`.
