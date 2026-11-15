# SignalScape: Requirements

ITSD 85 (Special Topics in Software Development) final project.

## 1. Overview

SignalScape is an Android app, built in Flutter, that maps a building's Wi-Fi coverage in 3D. A surveyor walks the building with a phone. The app records Wi-Fi signal strength (RSSI) along the way, estimates the phone's indoor position from step counting, the gyroscope and the compass, and detects the current floor with the barometer. Its own REST API stores the survey, fills in the coverage between readings with interpolation math, estimates where each access point is, and serves a floor-by-floor 3D view that highlights dead zones.

**Target users:** owners and facility managers of small and medium establishments (cafés, boarding houses, dormitories, clinics, small offices, schools) who need to find Wi-Fi dead zones and plan router placement but can't afford a professional site survey. **Pilot site:** our college, CISC, which has several known Wi-Fi dead zones; it will be surveyed for testing and the live demo.

## 2. Problem

Wi-Fi dead zones in buildings are usually found through complaints or guesswork. Professional site-survey tools cost money or need floor plans and manual pinning. SignalScape gives a phone-only way to see where coverage is weak and roughly where the access points are.

## 3. Goal

Turn a walk-through of a building into a 3D Wi-Fi coverage map, using only a phone's built-in sensors, on a full-stack system that meets the course's technical rules.

## 4. Objectives

1. Collect RSSI readings tagged with an estimated position (latitude and longitude) and floor, using one GPS fix at the start of the survey plus pedestrian dead reckoning, with no extra hardware.
2. Estimate coverage between readings with mathematical interpolation (no trained model needed), served behind its own REST API.
3. Estimate the physical location of each access point from its readings.
4. Show coverage per floor in a Three.js 3D view and a 2D map (floors as layers), with dead zones and estimated access points marked.
5. Meet the course's technical rules (section 7).
6. Handle survey data in line with RA 10173 (Data Privacy Act of 2012).
7. Test on a real building and write it up as an IEEE paper.

## 5. Scope

**In scope**
- Wi-Fi only (2.4 GHz and 5 GHz networks the phone can scan).
- Android phones.
- Positioning anchored to a GPS fix at survey start, then pedestrian dead reckoning (steps plus heading), with checkpoints to correct drift. Positions are stored as latitude and longitude.
- Floor detection by barometric pressure changes.
- Server-side data cleaning of readings (range checks, de-duplication, outlier removal).
- Coverage interpolation per floor by inverse distance weighting (IDW); kriging only as a comparison in the paper.
- Access point location estimation.
- 3D floor-by-floor visualization with Three.js.
- 2D map view from GeoJSON, one layer per floor.
- Offline-first capture with background sync.

**Out of scope**
- Cellular signal mapping.
- iOS (iPhones don't let apps read nearby networks' signal strength).
- Trained machine-learning models.
- Changing or configuring the network itself.

## 6. Functional requirements

### 6.1 Accounts and roles
- FR-1: Users register and sign in. The API issues JWTs.
- FR-2: At least 2 roles. Proposed: **Admin** (manages users, all buildings and surveys) and **Surveyor** (creates buildings, runs surveys, views their own maps). A **Viewer** role can only view surveys shared with them (survey shares).
- FR-3: Role-based access control is enforced on the API, not just hidden in the app.
- FR-3a: Passwords hashed with bcrypt.
- FR-3b: Input validation on every endpoint, and pagination, filtering and sorting on every list endpoint.
- FR-3c: Health check at `/api/health`.

### 6.2 Buildings and floors
- FR-4: Create, edit, list and delete buildings.
- FR-5: Define floors per building (level, label, optional approximate size), and optionally upload a floor plan image (PNG or JPEG, up to 5 MB).

### 6.3 Survey capture (app)
- FR-6: Start, pause and end a survey session for a building.
- FR-7: Scan Wi-Fi networks periodically and record SSID, BSSID, RSSI (dBm), frequency and timestamp.
- FR-8: Take a GPS fix at survey start (accuracy 10 m or better) as the origin, then track position with step detection, step length and heading (gyroscope plus compass). Each reading is tagged with latitude, longitude and estimated accuracy.
- FR-9: Detect floor changes with the barometer and tag readings with the floor.
- FR-10: Correct position drift with checkpoints: the surveyor taps their real position, or the app uses a GPS fix with accuracy 10 m or better. The error is spread over the readings since the last checkpoint.
- FR-11: Save every reading on the phone first, then upload in background batches with retries. Each reading has a phone-generated ID so re-uploads are never stored twice.
- FR-11a: During a survey, show a live trail colored by signal level, and when online, a preview heatmap refreshed about every 60 seconds.

### 6.4 Processing (API)
- FR-12: Validate and store uploaded readings, then clean them before processing: drop out-of-range values, merge repeat scans of the same access point at the same spot (median RSSI), and remove outliers.
- FR-13: Build a coverage grid per floor and per network (or the strongest signal) using inverse distance weighting.
- FR-14: Estimate each access point's position with a weighted centroid of its strongest readings (a log-distance path-loss fit can replace it later).
- FR-15: Classify grid cells into signal levels (for example good above -67 dBm, fair -67 to -80 dBm, dead below -80 dBm; thresholds configurable).

### 6.5 Visualization
- FR-16: A 3D view (a Three.js page served by the API, opened in the app through a WebView) shows the floors stacked, with a coverage heatmap per floor.
- FR-16a: A 2D map view shows the same coverage from GeoJSON, with one layer per floor.
- FR-17: Filter by network (SSID/BSSID) and by floor.
- FR-18: Mark dead zones and estimated access point positions.
- FR-19: Show a survey summary (area covered, number of readings, percentage of dead zones per floor).

### 6.6 Data and privacy
- FR-20: Users can view and delete their own surveys and account.
- FR-21: Export a survey's readings as CSV, and its coverage, access points and readings as GeoJSON.
- FR-22: A privacy notice and consent screen before the first survey.

## 7. Course technical requirements

| # | Requirement | How SignalScape meets it |
|---|---|---|
| C-1 | Team of 2 to 3, 8 weeks | Solo (Boon); confirm the instructor allows a solo project |
| C-2 | Separate client app plus own REST API | Flutter app in `app/`, REST API in `api/`; no direct database access from the app |
| C-3 | 8 or more screens | See section 8 |
| C-4 | Postgres or MySQL | PostgreSQL |
| C-5 | Docker | API, database and reverse proxy in Docker Compose |
| C-6 | Caddy | Caddy as the reverse proxy with automatic HTTPS |
| C-7 | GitHub Actions auto-deploy | Full CI/CD pipeline with tests, builds and auto-deploy (section 10) |
| C-8 | Public HTTPS | `https://signalscape.boonbrigoli.site`, served by Caddy with automatic HTTPS |
| C-9 | JWT auth with 2+ roles | Admin and Surveyor (plus optional Viewer) |
| C-10 | OpenAPI docs at /api/docs | Generated from the API and served at `/api/docs` |
| C-11 | Documentation plus IEEE paper | System documentation, user manual, API reference and IEEE paper in week 7 |
| C-14 | Enabling technology through the API | Interpolation and access point estimation served by the API; indoor positioning from phone sensors |
| C-15 | Real problem for an identifiable user group, not CRUD-only | Coverage mapping for small and medium establishment owners; CISC as pilot site |
| C-16 | 60% backend line coverage in CI | Enforced in CI (CI-2) |
| C-17 | Self-hosted GitHub Actions runner, redeploy on merge to main | Section 10 |
| C-18 | `/api/health`, pagination, filtering, sorting, validation, bcrypt | FR-3a to FR-3c |
| C-19 | Repo tagged `v1.0`, signed scoresheet, live demo | Week 8 |
| C-12 | RA 10173 compliance | Section 9 |
| C-13 | New build for the course, public repo | New project, not reused from any client work |

## 8. Screens (minimum 8)

1. Sign in
2. Register
3. Privacy notice and consent
4. Home / building list
5. Building details (floors)
6. Add or edit building and floors
7. Survey capture (live readings, step count, floor, checkpoints)
8. Survey list / history
9. 3D coverage view and 2D map view
10. Survey summary and export
11. Profile and settings (thresholds, delete account)
12. Admin: user management

## 9. Data privacy (RA 10173)

- Personal data stored: account details (name, email, hashed password), and survey data that shows where a user walked inside a building and when.
- Collect only what's needed. Location is collected only during an active survey (a GPS fix at the start, then estimated positions inside the building) and is treated as personal data. No contacts or device identifiers beyond what auth needs.
- Consent before the first survey, with a clear privacy notice.
- Passwords hashed (bcrypt or argon2). HTTPS everywhere. Role-based access to surveys.
- Users can view, export and delete their data. Deleting a survey or account removes its readings, results and uploaded floor plans.
- Network names (SSIDs) and BSSIDs belong to the building's networks; surveys should only be run where the user is allowed to.

## 10. CI/CD pipeline (GitHub Actions)

Runs on every push and pull request. Merges to `main` deploy automatically. **Course rule: deploys run on a self-hosted GitHub Actions runner** installed on the server, so the deploy job runs Docker Compose locally instead of over SSH.

**API (`api/`)**
- CI-1: Lint and format check.
- CI-2: Unit tests (auth, roles, CRUD, interpolation and access point math) with a coverage report. **The build fails below 60% backend line coverage** (course rule).
- CI-3: Integration tests against a PostgreSQL service container (migrations, endpoints, role checks).
- CI-4: OpenAPI spec check: the spec builds and `/api/docs` loads.
- CI-5: Build the Docker image.
- CI-6: Dependency and secret scanning (for example `npm audit`/`pip-audit` and GitHub secret scanning).

**App (`app/`)**
- CI-7: `flutter analyze` and `dart format` check.
- CI-8: `flutter test` (unit and widget tests: sensor processing, step and floor logic, API client).
- CI-9: Build a release APK and attach it to the workflow run (and to GitHub Releases on tags).

**Deploy (on merge to `main`, only if every check passes)**
- CD-1: Push the API image to a registry (for example GitHub Container Registry).
- CD-2: The self-hosted runner on the server pulls the new image, runs database migrations, and restarts with Docker Compose behind Caddy.
- CD-3: Smoke test after deploy: `/api/health` and `/api/docs` respond over HTTPS. Fail the run if not.
- CD-4: Secrets (server key, database URL, JWT secret) live in GitHub Actions secrets, never in the repo.
- CD-5: Branch protection on `main`: pull requests need passing checks before merging.
- CD-6: Tag the final release `v1.0`.

## 11. Non-functional requirements

- NFR-1: Survey upload and map generation for one floor (up to a few thousand readings) completes in under 30 seconds.
- NFR-2: The app keeps recording if the connection drops.
- NFR-3: Position drift stays usable with checkpoints (target: within a few meters per floor).
- NFR-4: The API has automated tests that run in CI.

## 12. Known constraints and risks

- Android throttles Wi-Fi scans to about 4 every 2 minutes per app by default. Test phones should turn off Wi-Fi scan throttling in Developer options, or surveys must walk slowly.
- Wi-Fi scanning on Android needs location permission and location services on.
- Step-counting positions drift over distance, so checkpoints are required for usable maps.
- Barometer readings vary with weather and the HVAC, so floor detection uses relative pressure changes during a session, not absolute values.
- Not every phone has a barometer, so manual floor selection is the fallback.
- Indoor GPS is often 5 to 30 m off, so only the start fix and good fixes (10 m or better) are used; the surveyor should start near an entrance or window.

## 13. Open questions

- Week 1 start date and the Classroom due dates.

Resolved (see section 14): proposal approved; interpolation is IDW and access point estimation is a weighted centroid; the API framework is FastAPI; the 3D view is a page served by the API and opened in a WebView.

## 14. Change log

Newest first. Times are Asia/Manila (UTC+8).

### 2026-11-15
- **Buildings and floors** built ([PR #7](https://github.com/Brigoliboon/signalscape/pull/7)): CRUD with pagination, sorting and search, floor plan upload, and role rules. Floor size is now optional (FR-5).
- **Sign-in and roles** built and merged ([PR #5](https://github.com/Brigoliboon/signalscape/pull/5)): JWT, bcrypt, Admin, Surveyor and Viewer roles, and admin user management (FR-1 to FR-3b).
- **Week 2 design** approved and merged ([PR #4](https://github.com/Brigoliboon/signalscape/pull/4), `docs/DESIGN.md`). Decisions recorded here:
  - Positions are latitude and longitude from a GPS fix at survey start plus dead reckoning (objective 1, FR-8, FR-10). The privacy section now treats location as personal data.
  - Server-side data cleaning before processing (FR-12).
  - IDW for coverage and a weighted centroid for access points (FR-13, FR-14).
  - Offline-first capture with background sync, and live visuals during a survey (FR-11, FR-11a).
  - A 2D map view and GeoJSON export, with floors as layers (FR-16a, FR-21).
  - The 3D view is a page served by the API in a WebView (FR-16).
  - The Viewer role sees only surveys shared with them (FR-2).
- **CI/CD** live ([PR #1](https://github.com/Brigoliboon/signalscape/pull/1) to [PR #3](https://github.com/Brigoliboon/signalscape/pull/3)): tests, builds and auto-deploy on a self-hosted runner, public HTTPS at `signalscape.boonbrigoli.site` (C-8), branch protection on `main` (CD-5), and path filters so only changed parts are checked.

