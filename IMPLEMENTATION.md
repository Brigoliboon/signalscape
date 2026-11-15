# SignalScape: Implementation Checkpoints

Tracks build progress by week. Course milestones: proposal (week 1), design (week 2), MVP (weeks 3 to 4), feature-complete and deployed (weeks 5 to 6), testing and docs (week 7), defense (week 8). Missing a milestone costs points. See `REQUIREMENTS.md` for what each item means. Tick items as they're done.

**Repo layout**
- `api/`: REST API, database migrations, interpolation and access point estimation, Docker setup.
- `app/`: Flutter Android app.

**Status:** M3 in progress (Nov 15, 2026). Week dates are set once week 1's start is confirmed.

---

## M1, Week 1: Proposal and feasibility
- [x] Problem, goal, objectives and scope agreed (see REQUIREMENTS.md)
- [x] Public GitHub repo created
- [ ] Feasibility check on my phone: Wi-Fi scan rate (with and without throttling), step detection, compass and gyroscope, and barometer present
- [x] Target user group named (small and medium establishment owners; CISC as pilot site)
- [ ] Up to 3 titles proposed
- [x] Proposal submitted and approved (no work counts before approval)

## M2, Week 2: Design
- [x] Database schema (users, roles, buildings, floors, survey sessions, readings, checkpoints, access points, coverage grids)
- [x] OpenAPI spec draft (endpoints for auth, buildings, floors, surveys, readings, maps, admin)
- [ ] Wireframes for the 8+ screens
- [x] Interpolation and access point estimation methods chosen
- [ ] RA 10173 privacy notice and data handling plan
- [x] API framework chosen (FastAPI)
- [ ] Flutter packages chosen

## M3, Week 3: API foundation and deployment (MVP part 1)
- [x] API project set up in `api/`
- [x] PostgreSQL with migrations
- [x] Register and sign-in with JWT (FR-1)
- [x] Roles and access control: Admin, Surveyor (FR-2, FR-3)
- [x] Buildings and floors CRUD (FR-4, FR-5)
- [x] bcrypt, input validation, pagination, filtering and sorting on list endpoints (FR-3a, FR-3b)
- [x] `/api/health` (FR-3c)
- [x] OpenAPI docs served at `/api/docs` (C-10)
- [x] Docker Compose: API, PostgreSQL, Caddy (C-5, C-6)
- [x] Public HTTPS domain (C-8)
- [x] CI for the API: lint, unit tests, integration tests with a PostgreSQL container, OpenAPI check, Docker build, dependency scan (CI-1 to CI-6)
- [x] Self-hosted GitHub Actions runner installed on the server
- [x] CD: build the image, deploy with Docker Compose on the runner, run migrations, post-deploy smoke test (CD-1 to CD-4).
- [x] CI fails below 60% backend line coverage (CI-2)
- [x] Branch protection on `main` with required checks (CD-5)

## M4, Week 4: Survey capture in the app (MVP part 2, MVP due end of week 4)
- [ ] Flutter project set up in `app/`
- [ ] CI for the app: `flutter analyze`, format check, `flutter test`, release APK build (CI-7 to CI-9)
- [ ] Sign in, register and consent screens wired to the API
- [ ] Building list, details and edit screens
- [ ] Wi-Fi scanning: SSID, BSSID, RSSI, frequency, timestamp (FR-7)
- [ ] Step detection and heading for position (FR-8)
- [ ] Barometer floor detection, with manual floor fallback (FR-9)
- [ ] Checkpoints to correct drift (FR-10)
- [ ] Offline storage and upload to the API (FR-11)
- [x] Survey readings upload endpoint (FR-12)
- [ ] Live trail colored by signal level during a survey, and a preview heatmap refreshed about every 60 s when online (FR-11a)

## M5, Week 5: Processing (feature-complete part 1)
- [ ] Coverage grid per floor and per network by interpolation (FR-13)
- [ ] Access point position estimation (FR-14)
- [ ] Signal level classification with configurable thresholds (FR-15)
- [ ] Map endpoints return grids and access points per floor
- [ ] Unit tests for the interpolation and access point math, run in CI

## M6, Week 6: 3D view and remaining screens (feature-complete and deployed, due end of week 6)
- [ ] Three.js 3D view with stacked floors and coverage heatmaps (FR-16)
- [ ] Filter by network and floor (FR-17)
- [ ] Dead zones and estimated access points marked (FR-18)
- [ ] Survey summary and CSV export (FR-19, FR-21)
- [ ] 2D map view from GeoJSON, one layer per floor (FR-16a)
- [ ] GeoJSON export of coverage, access points and readings (FR-21)
- [ ] Survey history, profile and settings, delete account (FR-20)
- [ ] Admin user management screen
- [ ] All 8+ screens done (C-3)

## M7, Week 7: Testing, docs and paper
- [ ] Full survey of a real building (at least 2 floors)
- [ ] Bug fixes and accuracy check (position drift, floor detection, access point estimates against the real locations)
- [ ] Privacy checks against RA 10173 (consent, deletion, access control)
- [ ] System documentation, user manual and API reference
- [ ] Backend coverage at 60% or more
- [ ] IEEE paper draft

## M8, Week 8: Defense
- [ ] Final deploy through the pipeline, all checks green, demo data ready
- [ ] Slides and demo run-through
- [ ] IEEE paper final
- [ ] Repo tagged `v1.0`
- [ ] Signed scoresheet
- [ ] Live demo and defense

---

## Progress log
- 2026-11-15 20:30: [PR #10](https://github.com/Brigoliboon/signalscape/pull/10) open: surveys API (migration 0004). Start, pause, resume and complete a survey (GPS start fix of 10 m or better, consent required for Surveyors), batch upload of readings and checkpoints that skips repeated `client_id`s (FR-12), and survey shares so Viewers see only shared surveys. Admin sees all, Surveyor own. 201 tests, 100% coverage. Ticked the readings upload endpoint (FR-12); the app side of checkpoints, offline sync and live visuals stays open.
- 2026-11-15 20:03: [PR #8](https://github.com/Brigoliboon/signalscape/pull/8) open: `REQUIREMENTS.md` updated with the week 2 decisions (GPS fix plus dead reckoning, data cleaning, IDW and weighted centroid, offline sync, live visuals FR-11a, 2D GeoJSON map FR-16a, 3D view in a WebView, Viewers through shares, optional floor size), privacy section for location data, and a change log in section 14. Records FastAPI as the API framework; Flutter package choices still open. Added FR-11a to M4 and FR-16a and GeoJSON export to M6 here.
- 2026-11-15 20:03: [PR #7](https://github.com/Brigoliboon/signalscape/pull/7) open: buildings and floors CRUD (migration 0003) with pagination, sorting and search; floor plan upload (PNG or JPEG, up to 5 MB) in a new `uploads_data` volume; Admin full access, Surveyor own buildings only, Viewer none; plan files removed on delete. 124 tests, 100% coverage. Tick FR-4, FR-5 and FR-3a/FR-3b once merged.
- 2026-11-15 19:42: M3 auth merged ([PR #5](https://github.com/Brigoliboon/signalscape/pull/5)). Users table (migration 0002), bcrypt password hashing, JWT sign-in, Admin, Surveyor and Viewer roles, register, login, profile and consent endpoints, admin user management, and a CLI to create the first admin. Shared pagination and sorting helper for list endpoints. 53 tests, 100% backend coverage. CI and CD green; deployed. Next: buildings and floors CRUD (FR-4, FR-5).
- 2026-11-15 19:37: Week 2 design merged ([PR #4](https://github.com/Brigoliboon/signalscape/pull/4), `docs/DESIGN.md`). Database schema, access control, REST API with paging, filtering and sorting, processing math (cleaning, IDW interpolation, access point estimates), offline-first client sync, and GeoJSON output per floor. Still open for week 2: wireframes, RA 10173 privacy plan, package choices.
- 2026-11-15 18:28: CI path filters merged ([PR #3](https://github.com/Brigoliboon/signalscape/pull/3)), so API and app jobs run only when their files change.
- 2026-11-15 18:12: First green deploy. [PR #2](https://github.com/Brigoliboon/signalscape/pull/2) fixed the CD smoke test for the VM's older curl after the first deploy from PR #1 failed. `https://signalscape.boonbrigoli.site/api/health` returns ok. Branch ruleset `protect-main` is active (PRs, required checks, no force push or deletion).
- 2026-11-15 17:55: M3 API foundation and CI/CD merged ([PR #1](https://github.com/Brigoliboon/signalscape/pull/1)). Switched from Cloudflare Tunnel to Caddy serving HTTPS directly (GoDaddy A record to the VM, ports 80 and 443). CI pins Flutter 3.41.6 and Java 17 for the Android build.
- 2026-11-15: M3 CI/CD. GitHub Actions CI on every push and PR: ruff lint/format (CI-1), pytest against a Postgres container with a 60% coverage fail gate (CI-2, CI-3), OpenAPI/`/api/docs` check (CI-4), Docker image build (CI-5), pip-audit and gitleaks (CI-6). CD after CI succeeds on a push to `main`: push the API image to GHCR (CD-1), self-hosted runner pulls it, restarts Docker Compose, runs migrations, smoke tests `/api/health` and `/api/docs` (CD-2, CD-3). Secrets stay in GitHub Actions (CD-4). Flutter CI (CI-7 to CI-9) runs on `app/`. Self-hosted runner `signalscape-vm` is online on the VM with Docker installed; `POSTGRES_PASSWORD` and `JWT_SECRET` secrets set. Caddy serves `signalscape.boonbrigoli.site` with automatic HTTPS (A record to the VM, ports 80/443). Still open: first green deploy, branch protection (CD-5), public HTTPS domain (C-8).
- 2026-11-15: M3 API foundation. FastAPI project in `api/` with Alembic, `/api/health` (FR-3c), OpenAPI at `/api/docs` (C-10), and Docker Compose for the API, PostgreSQL, and Caddy (C-5, C-6). Auth, roles, and buildings CRUD are not started.
- 2026-11-15: Project picked. REQUIREMENTS.md and IMPLEMENTATION.md drafted. CI/CD pipeline requirements added. Updated against Sage's full course guidelines (user group, self-hosted runner, 60% coverage, /api/health, v1.0 tag).
