# SignalScape: Implementation Checkpoints

Tracks build progress by week. Course milestones: proposal (week 1), design (week 2), MVP (weeks 3 to 4), feature-complete and deployed (weeks 5 to 6), testing and docs (week 7), defense (week 8). Missing a milestone costs points. See `REQUIREMENTS.md` for what each item means. Tick items as they're done.

**Repo layout**
- `api/`: REST API, database migrations, interpolation and access point estimation, Docker setup.
- `app/`: Flutter Android app.

**Status (Nov 16, 2026):** M3 and M5 are done. M6's backend is mostly done (3D view page, filters, markers, GeoJSON export); its summary, 2D map, history and admin screens are open. M4 is code-complete and CI-green in the app (register and consent, building and floor management with plans, barometer floors, drift-corrected checkpoints, live preview heatmap, resume), but nothing in M4 has been tested on a real phone yet, so FR-7, FR-8, FR-9, FR-10 and FR-11a still need that test. Week dates are set once week 1's start is confirmed.

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
- [x] Wireframes for the 8+ screens
- [x] Interpolation and access point estimation methods chosen
- [ ] RA 10173 privacy notice and data handling plan
- [x] API framework chosen (FastAPI)
- [x] Flutter packages chosen (pinned in `app/pubspec.yaml`: `flutter_secure_storage`, `wifi_scan`, `sensors_plus`, `geolocator`, `permission_handler`, `sqflite`, `connectivity_plus`, `webview_flutter`, `http`, `uuid`, `path`)

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
- [x] Flutter project set up in `app/`
- [x] CI for the app: `flutter analyze`, format check, `flutter test`, release APK build (CI-7 to CI-9)
- [x] Sign in, register and consent screens wired to the API
- [x] Building list, details and edit screens
- [x] Wi-Fi scanning: SSID, BSSID, RSSI, frequency, timestamp (FR-7) (code done, CI green, still to be tested on a real phone)
- [x] Step detection and heading for position (FR-8) (code done, CI green, still to be tested on a real phone)
- [x] Barometer floor detection, with manual floor fallback (FR-9) (code done, CI green, still to be tested on a real phone)
- [x] Checkpoints to correct drift (FR-10) (code done, CI green, still to be tested on a real phone)
- [x] Offline storage and upload to the API (FR-11)
- [x] Survey readings upload endpoint (FR-12)
- [x] Live trail colored by signal level during a survey, and a preview heatmap refreshed about every 60 s when online (FR-11a) (code done, CI green, still to be tested on a real phone)

## M5, Week 5: Processing (feature-complete part 1)
- [x] Coverage grid per floor and per network by interpolation (FR-13)
- [x] Access point position estimation (FR-14)
- [x] Signal level classification with configurable thresholds (FR-15)
- [x] Map endpoints return grids and access points per floor
- [x] Unit tests for the interpolation and access point math, run in CI

## M6, Week 6: 3D view and remaining screens (feature-complete and deployed, due end of week 6)
- [x] Three.js 3D view with stacked floors and coverage heatmaps (FR-16)
- [x] Filter by network and floor (FR-17)
- [x] Dead zones and estimated access points marked (FR-18)
- [ ] Survey summary and CSV export (FR-19, FR-21)
- [x] 2D map view from GeoJSON, one layer per floor (FR-16a) (code done, CI green; still to be tested on a real phone, and the Mapbox token has to be set as the `MAPBOX_TOKEN` secret for Mapbox tiles)
- [x] GeoJSON export of coverage, access points and readings (FR-21)
- [ ] Survey history, profile and settings, delete account (FR-20)
- [ ] Admin user management screen
- [ ] All 8+ screens done (C-3)

## M7, Week 7: Testing, docs and paper
- [ ] Full survey of a real building (at least 2 floors)
- [ ] Bug fixes and accuracy check (position drift, floor detection, access point estimates against the real locations)
- [ ] Privacy checks against RA 10173 (consent, deletion, access control)
- [x] System documentation, user manual and API reference (`docs/`: CI_CD, DEPLOYMENT, BRANCHING, LOCAL_DEV, CONFIG_AND_SECRETS, RUNBOOK, API_GUIDE, USER_GUIDE; to be re-read against the final app before the defense)
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
- 2026-11-16 17:00: Smooth heatmap (branch `feat/smooth-heatmap`), display only, no API or database change. After comparing with Acrylic Wi-Fi Heatmaps, the 3D page, the 2D map and the live preview draw the grid as one continuous picture instead of flat 1 m cells: bilinear upsampling (6 px per cell, picture capped at 2048 px; empty cells left out of the blend so colour never bleeds, soft rounded edge about one cell wide, still faded by confidence), a rainbow ramp from red at -30 dBm through orange, yellow, green and cyan to dark blue at -100 dBm (stops in `docs/DESIGN.md`), and thin black contour lines every 5 dB by marching squares. New controls on both maps: Opacity (default 85%), Min RSSI (hides weaker values, contours included) and a contour switch; the legend is a gradient bar with dBm ticks, with the surveyor's thresholds as text. Tapping still gives the nearest cell's own value and its good, fair or dead level. 3D page: canvas texture from new `heat.mjs` (CSP unchanged). 2D map: the cells from `/geojson` are put back into a grid, drawn in an isolate, encoded to PNG and shown by `OverlayImageLayer` at the grid's bounds, cached by floor, network and settings; the live preview uses the same ramp without contours. Shared maths exists twice (`heat.mjs`, `heatmap.dart`) with tests for the ramp, upsampling with empty cells, marching squares, the cut-off and the controls. Docs updated: `DESIGN.md` (new Heatmap display section), `USER_GUIDE.md`, `LOCAL_DEV.md`, `API_GUIDE.md`. Looked at in headless Chromium with seeded data (3D page, sliders and tap); not yet seen on a phone. Nothing ticked.
- 2026-11-16 16:30: Docs for the pipeline, the server and day-to-day use (branch `docs/devops-and-guides`). Eight new Markdown files in `docs/`, linked from the README: `CI_CD.md` (device to live server, every CI and CD job), `DEPLOYMENT.md` (VM, self-hosted runner service, Compose, Caddy and TLS, DNS, SSH with a key file, manual deploy, create-admin), `BRANCHING.md` (branch names, PR flow, the real `protect-main` ruleset), `LOCAL_DEV.md`, `CONFIG_AND_SECRETS.md` (names only), `RUNBOOK.md` (logs, restart, rollback, key rotation, site-down checklist, reprocessing), `API_GUIDE.md` (curl examples with real responses from a local run of `main`) and `USER_GUIDE.md` (surveyor guide from the app's screens). Checked against the repo, GitHub settings and the VM (read-only); what could not be checked is listed at the end of each file. Findings worth acting on: there is no database backup on the server (the runbook has recommended commands), and the heatmap accuracy work (PR #18) was merged into the already merged PR #17 branch, not into `main`. Ticked the system documentation, user manual and API reference item.
- 2026-11-16 15:40: Heatmap accuracy (branch `feat/heatmap-accuracy`). The first phone test showed a vague heatmap with too little data. Processing now fills cells only within 5 m of a reading (was 10 m; cells with none stay empty) and gives every cell a confidence from 0 to 1, `min(1, n/4) * (1 - nearest/radius)`, stored in a new nullable `coverage_grids.confidence` column (migration 0006, safe on existing rows) and returned by `/coverage`, the preview and the `/geojson` cell properties. The 3D page smooths the heatmap with linear filtering and fades low-confidence cells; the 2D map, the live preview and the legends fade them too, with a note "Faded = few readings". Existing surveys keep their old grids until processed again through `POST /process`. Design notes in `docs/DESIGN.md`. Nothing ticked. Still to be tested on a real phone with Wi-Fi scan throttling off.
- 2026-11-16 05:30: 2D map revisions (branch `feat/map-satellite-networks`). The map now uses Mapbox satellite imagery with labels (`satellite-streets-v12`; OpenStreetMap street map without a token), with stronger cell colours and edges, a dark casing on the walk and shadows on the markers so they read on bright imagery. New network picker like the 3D view's: all networks (strongest signal) or one network by SSID, BSSID and reading count; the cells and access points reload for that network through `/geojson?bssid=` (already supported by the API). Checked the 3D view's network picker with the trail and footprint from PR #15 in a Node harness with stubbed WebGL: switching network rebuilds each floor with its trail, start and end and footprint intact. Still to be tested on a real phone.
- 2026-11-16 05:00: 2D map screen (branch `feat/2d-map`, FR-16a). `flutter_map` with Mapbox `dark-v11` raster tiles when the build has `--dart-define=MAPBOX_TOKEN=...`, else OpenStreetMap tiles; attribution for whichever is used. Reads `/summary`, `/geojson` and `/trail`; draws the coverage cells coloured good/fair/dead, tappable access point markers (SSID, BSSID, strongest RSSI), the walk with start and end markers, a floor selector (one floor's layers at a time), per-layer toggles and a legend with the surveyor's thresholds; fits to the data. Opened from the 3D view's app bar (which is where a survey lands after End survey) and back. Not processed yet: a message, with a Process now button for Surveyors and Admins. Loading, empty, error and offline states. CI passes the token through `--dart-define` (an empty secret still builds). Still to be tested on a real phone.\n- 2026-11-16 04:30: Trail fixes from the first phone test (branch `feat/trail-fixes`). The live trail now draws a solid line through every step plus outlined scan dots and a start marker, and fits the walk instead of the heatmap (Android's scan limit gave only about 4 dots, and they blended into the preview). New `GET /surveys/{id}/trail`; the 3D page draws the walked path per floor with Start and End markers (toggle in Layers), and the floor footprint now shows only cells with data instead of a full rectangle. Nothing ticked: FR-11a and FR-16 still need the phone test of this change.
- 2026-11-16 02:36: M4 finished in code (branch `feat/m4-complete`). **Register** screen on `POST /auth/register` (linked from sign in, signs in afterwards) and a full **consent** screen with the privacy notice from REQUIREMENTS section 9 (FR-22, RA 10173). **Buildings**: the home screen is now a building list with search, sort and paging, a details screen with floors, add and edit for buildings and floors (floor height, optional size), and floor plan upload from the photo picker (PNG or JPEG, up to 5 MB, checked on the phone first); Viewers get no create or edit buttons (and the API shows them no buildings). **Barometer (FR-9)**: calibrates at the start on the chosen floor, turns the pressure change into floors with each floor's height (3.3 m if a floor has none), needs 25% of a floor more clearly plus 3 s on the new floor before it reports a change, suggests the floor (or switches by itself if Auto-switch is on), and a manual pick always wins and re-bases; no barometer means manual floors. **Preview heatmap (FR-11a)**: about every 60 s while online it calls `POST /process?preview=true` for the current floor and draws the strongest-signal grid under the trail; offline or an error keeps the last grid, marked old. **Checkpoints (FR-10)**: a checkpoint with a good GPS fix now spreads its error back over the readings since the last good fix, in proportion to steps walked, before they are uploaded; readings wait on the phone for that (at most 4 minutes, then they go up uncorrected), so the live preview lags by up to that long. A tap checkpoint without a good fix only marks the place, so correcting from a position tapped on the floor plan (the design's other checkpoint kind) is not built. **Resume**: the app remembers an unfinished survey, and on the next launch offers Resume, End survey (upload and process) or Later. Tests: 120 new unit and widget tests (175 in total), including SQLite tests on the host. Not yet done: real-phone checks of FR-7, FR-8, FR-9, FR-10 and FR-11a (the barometer thresholds and the drift spread may need tuning), delete for buildings and floors in the app.
- 2026-11-16 01:30: App POC open as a PR (branch `feat/app-poc`). Sign in (token in secure storage, base URL from `--dart-define=API_BASE_URL`), a minimal privacy consent screen for Surveyors (Admins are not asked by the API), a building and floor pick with quick create, then survey capture: GPS start fix of 10 m or better, Wi-Fi scans kept within Android's 4 scans per 2 minutes, steps and compass heading for dead reckoning, a checkpoint that re-anchors to a good GPS fix, pause, end, sqflite queue with batched retrying sync (5 s, 10 s, 30 s, 2 min), a live trail colored good/fair/dead, and the 3D page in a WebView after processing. Dark "signal scanner" theme in `app/lib/theme.dart`. Unit tests for the step, heading and position math, scan throttle, sync queue, signal levels, API client and sign in (55 tests). Ticked: wireframes (M2) and Flutter packages (M2). Left unticked on purpose until tried on a real phone: Wi-Fi scanning (FR-7), step detection and heading (FR-8), checkpoints (FR-10), offline storage and upload (FR-11) and the live trail (FR-11a; the 60 s preview heatmap is not built). Also still open: register screen, building screens, barometer floor detection (FR-9, the floor is picked by hand).
- 2026-11-16 00:45: 3D coverage page open as a PR (branch `feat/3d-view`). Static Three.js page at `/api/viewer/`, served by the API, for the app's WebView. Stacked floors with a good/fair/dead heatmap using the surveyor's thresholds, a legend with text labels, estimated access point markers, highlighted dead zones (FR-18), floor toggles and a network filter (FR-17), tap to inspect, one-finger orbit and two-finger zoom on a 360×800 phone. JWT goes in the URL fragment and is kept in memory only; the page is public and holds no data. Three.js r0.187.0 vendored, no build step. `/summary` now returns `floor_height_m` per floor. Ticked FR-16 (page), FR-17 and FR-18. Still open: opening the page from the Flutter app in a WebView, and the 2D map (FR-16a).
- 2026-11-16 00:35: [PR #11](https://github.com/Brigoliboon/signalscape/pull/11) open: survey processing (migration 0005, numpy). Cleaning (range check, median merge of repeat scans, MAD outliers), IDW coverage on a 1 m grid with a 10 m radius per floor and per network, weighted-centroid access point estimates, signal levels from the surveyor's thresholds. `POST /surveys/{id}/process` (full run on a completed survey, or `preview=true` for the live heatmap), plus `coverage`, `access-points`, `summary`, `networks`, `geojson` (floors as layers) and `export.csv`. 273 tests, 100% coverage. Ticked FR-13 to FR-15, the map endpoints, the math tests and the GeoJSON export. Still open on the app side: FR-11a live heatmap, FR-16 and FR-16a views, FR-18 markers and FR-19 summary screen (their API is done), and the CSV export button.
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
