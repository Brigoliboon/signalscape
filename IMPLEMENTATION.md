# SignalScape: Implementation Checkpoints

Tracks build progress by week. Course milestones: proposal (week 1), design (week 2), MVP (weeks 3 to 4), feature-complete and deployed (weeks 5 to 6), testing and docs (week 7), defense (week 8). Missing a milestone costs points. See `REQUIREMENTS.md` for what each item means. Tick items as they're done.

**Repo layout**
- `api/`: REST API, database migrations, interpolation and access point estimation, Docker setup.
- `app/`: Flutter Android app.

**Status:** M3 in progress (Nov 15, 2026). Week dates are set once week 1's start is confirmed.

---

## M1, Week 1: Proposal and feasibility
- [ ] Problem, goal, objectives and scope agreed (see REQUIREMENTS.md)
- [ ] Public GitHub repo created
- [ ] Feasibility check on my phone: Wi-Fi scan rate (with and without throttling), step detection, compass and gyroscope, and barometer present
- [x] Target user group named (small and medium establishment owners; CISC as pilot site)
- [ ] Up to 3 titles proposed
- [ ] Proposal submitted and approved (no work counts before approval)

## M2, Week 2: Design
- [ ] Database schema (users, roles, buildings, floors, survey sessions, readings, checkpoints, access points, coverage grids)
- [ ] OpenAPI spec draft (endpoints for auth, buildings, floors, surveys, readings, maps, admin)
- [ ] Wireframes for the 8+ screens
- [ ] Interpolation and access point estimation methods chosen
- [ ] RA 10173 privacy notice and data handling plan
- [ ] API framework and Flutter packages chosen

## M3, Week 3: API foundation and deployment (MVP part 1)
- [x] API project set up in `api/`
- [x] PostgreSQL with migrations
- [ ] Register and sign-in with JWT (FR-1)
- [ ] Roles and access control: Admin, Surveyor (FR-2, FR-3)
- [x] Buildings and floors CRUD (FR-4, FR-5)
- [x] bcrypt, input validation, pagination, filtering and sorting on list endpoints (FR-3a, FR-3b)
- [x] `/api/health` (FR-3c)
- [x] OpenAPI docs served at `/api/docs` (C-10)
- [x] Docker Compose: API, PostgreSQL, Caddy (C-5, C-6)
- [ ] Public HTTPS domain (C-8)
- [x] CI for the API: lint, unit tests, integration tests with a PostgreSQL container, OpenAPI check, Docker build, dependency scan (CI-1 to CI-6)
- [ ] Self-hosted GitHub Actions runner installed on the server
- [ ] CD: build the image, deploy with Docker Compose on the runner, run migrations, post-deploy smoke test (CD-1 to CD-4). Workflow written; tick after the first green deploy.
- [x] CI fails below 60% backend line coverage (CI-2)
- [ ] Branch protection on `main` with required checks (CD-5)

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
- [ ] Survey readings upload endpoint (FR-12)

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
- 2026-11-15: M3 CI/CD. GitHub Actions CI on every push and PR: ruff lint/format (CI-1), pytest against a Postgres container with a 60% coverage fail gate (CI-2, CI-3), OpenAPI/`/api/docs` check (CI-4), Docker image build (CI-5), pip-audit and gitleaks (CI-6). CD after CI succeeds on a push to `main`: push the API image to GHCR (CD-1), self-hosted runner pulls it, restarts Docker Compose, runs migrations, smoke tests `/api/health` and `/api/docs` (CD-2, CD-3). Secrets stay in GitHub Actions (CD-4). Flutter CI (CI-7 to CI-9) runs on `app/`. Self-hosted runner `signalscape-vm` is online on the VM with Docker installed; `POSTGRES_PASSWORD` and `JWT_SECRET` secrets set. Caddy serves `signalscape.boonbrigoli.site` with automatic HTTPS (A record to the VM, ports 80/443). Still open: first green deploy, branch protection (CD-5), public HTTPS domain (C-8).
- 2026-11-15: M3 API foundation. FastAPI project in `api/` with Alembic, `/api/health` (FR-3c), OpenAPI at `/api/docs` (C-10), and Docker Compose for the API, PostgreSQL, and Caddy (C-5, C-6). Auth, roles, and buildings CRUD are not started.
- 2026-11-15: Project picked. REQUIREMENTS.md and IMPLEMENTATION.md drafted. CI/CD pipeline requirements added. Updated against Sage's full course guidelines (user group, self-hosted runner, 60% coverage, /api/health, v1.0 tag).
