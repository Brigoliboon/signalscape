# SignalScape: Requirements

ITSD 85 (Special Topics in Software Development) final project.

> **Part 1** below is the v1.0 course release (tag `v1.0`). **Part 2** at the end is the v1.1 DTO extension, approved 2026-11-18. v1.1 IDs continue from FR-23 and NFR-5.

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
- FR-14: Estimate each access point's position with a weighted centroid of its strongest readings (a log-distance path-loss fit can replace it later). **Replaced in v1.1 by FR-23** (path-loss range plus best-fit position; see [Part 2: v1.1](#part-2-v11-dto-extension-approved-2026-11-18)).
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

---

## Part 2: v1.1 (DTO extension, approved 2026-11-18)

ITSD 85 (Special Topics in Software Development) final project, extended for the university Department of Tech Office (DTO). **Approved by Boon 2026-11-18.**

v1.0 (Part 1 above; tag [`v1.0`](https://github.com/Brigoliboon/signalscape/releases/tag/v1.0), 16 Nov 2026) stays in force. FR-1 to FR-22, NFR-1 to NFR-4 and C-1 to C-19 are unchanged unless a v1.1 item below replaces a method. New IDs continue from FR-23 and NFR-5.

Course grading is done. v1.1 is the DTO implementation, not further course work. The first slice (M9 and M10) is due 19 Nov 2026. The rest follows after.

Planned against `main` at `56b2b67` (v1.0 plus the post-release checklist tick).

### v1.1-1. Overview

SignalScape maps Wi-Fi coverage from a walk-through with a phone. v1.0 is an Android Flutter app plus its own FastAPI service: the phone records RSSI with pedestrian dead reckoning, the API cleans the data, builds an IDW coverage grid and estimates access point positions, and the app shows a 2D map and a Three.js 3D view (a page served by the API and opened in a WebView).

The course pilot site was CISC. The instructor is adopting SignalScape for DTO. v1.1 makes it usable there: a campus map of several buildings and the outdoor areas between them, plotted dead and weak zones, an AI analysis report, a per-router coverage mode, a fix for access point placement, a fuller admin view of surveyor work, and a web dashboard on `https://signalscape.boonbrigoli.site`.

**Target users:** DTO staff, who sign in with the existing Admin role, and the surveyors who walk the campus. No new role is added. The original small-establishment use in v1.0 remains.

### v1.1-2. Problem

v1.0 maps one survey at a time, on the phone, inside a single building. DTO needs a campus-scale view: several buildings plus the grounds between them, several surveys combined, dead and weak areas plotted, a written analysis they can export, a way to see each router's coverage and the gaps between chained extenders, and a browser view on a larger screen.

Three gaps in the current release also need work:

1. **Access point markers clamp together on small data.** This is the estimated *access point* positions (FR-14), not the walk trail. `estimate_access_points()` in `api/app/services/processing.py` takes each network's 10 strongest readings on one floor and places the marker at their power-weighted average (`10^(rssi/10)`, method `weighted_centroid`). A weighted average of places the surveyor stood can never sit outside the walked path, and the steep weights pull every router onto the same few strong or long-stood spots (the start, a checkpoint). The 2D and 3D markers are a single colour today; the detail text shows `max_rssi_dbm`, which is often in the "good" range even when the placement is poor. FR-14 already notes that a log-distance path-loss fit can replace the centroid later. That is this work.
2. **Admin view of surveyor work is only partial.** The API already lets an admin list every survey and filter by `surveyor_id`, and open any survey's readings, trail, results and export (`visible_surveys()` / `visible_buildings()` skip the owner check for admins). In the app, an admin's Survey History lists everyone's surveys and can open each one on the 2D or 3D map, but it never sends `surveyor_id`, the cards do not show who walked the survey (they store `surveyorId` only), and the Users screen cannot open a surveyor's surveys. There is no per-surveyor overview. A surveyor's area is whatever they actually surveyed; nobody assigns buildings or zones by hand, and v1.1 does not add an assignments table.
3. **No mode for tracing a router and its extenders** to see each router's coverage and the dead or weak signal between them.

### v1.1-3. Goal

Give DTO a campus map of buildings and outdoor areas, with combined surveys, plotted dead and weak zones, an exportable AI analysis report, and a browser dashboard, and fix access point placement, admin visibility of surveyor work, and per-router coverage tracing.

### v1.1-4. Objectives

1. Replace the weighted-centroid access point estimate with a path-loss range plus a best-fit position, so a marker can sit beyond the walked path, and show placement confidence instead of strongest RSSI.
2. Plot dead and weak areas as their own map layer.
3. Add a separate router coverage mode that counts each router, shows its coverage, and traces chained extenders so dead gaps between them are visible.
4. Let an admin see who walked each survey, filter History by surveyor, open a surveyor's surveys from the Users screen, and see a per-surveyor overview whose area is derived from those surveys.
5. Combine surveys onto a campus or site map that spans several buildings and the outdoor areas between them, using GPS for positions outdoors.
6. Produce an AI-written analysis report with a summary and recommendations, which DTO can export.
7. Offer a browser dashboard at `https://signalscape.boonbrigoli.site` for those consolidated maps and the report.

### v1.1-5. Scope

**In scope**
- Changes to the existing FastAPI service and Flutter Android app, plus a browser dashboard that reuses the existing 3D viewer page and 2D GeoJSON coverage where possible, hosted at `https://signalscape.boonbrigoli.site`.
- A new access point estimator (path-loss distance + best-fit / trilateration), confidence rules (at least 5 readings spread over 3 m or more; below that, a faded marker with a "low confidence" flag), and marker colouring by confidence on the 2D and 3D maps.
- A dedicated dead and weak zone layer on the maps (FR-15 already classifies cells as good, fair or dead; this makes that layer a first-class plot for DTO).
- A separate router coverage mode: count per router (BSSID / device) with SSIDs listed under each, each router's coverage footprint, and tracing of chained or extended routers with dead gaps between them.
- Admin History and Users work, plus a per-surveyor overview. A surveyor's area is derived from what they surveyed. No assignments table or routes.
- A campus or site map of several buildings and the outdoor areas between them, with GPS positioning outdoors, and consolidation of multiple surveys onto that map.
- An AI-written analysis report (summary and recommendations), generated by the API and exportable.
- Tests for the new estimator, count/coverage mode, consolidation and API routes, run in the existing CI.

**Out of scope**
- Cellular signal mapping, iOS, trained machine-learning models for coverage gap-filling, and changing or configuring the network itself (unchanged from v1.0). Gap filling stays IDW.
- A Flutter web (or other) rewrite of survey capture. Surveys still run on the Android phone.
- A new role. DTO staff use the existing Admin role. Existing Surveyor and Viewer roles, and survey shares (FR-2, FR-3), stay.
- A new survey-permission or share model, and any manual assignment of surveyors to buildings, floors, zones or areas. No assignments table.
- Recalibrating dead reckoning or step detection as the main position fix. Trail quality can still affect access point estimates if almost every reading sits on the start point; that is a follow-up if it still shows up after the new estimator, not the first slice.

### v1.1-6. Functional requirements

#### v1.1-6.1 Access point placement (replaces the weighted-centroid method in FR-14)

- FR-23: Estimate each access point with a log-distance path-loss range from RSSI plus a best-fit (trilateration) position, so the marker can sit outside the area the surveyor walked. Store the method name (the `method` column already exists; v1.0 writes `weighted_centroid`).
- FR-24: Placing a confident marker needs at least 5 readings spread over 3 m or more. Below that, still show the marker, faded, with a "low confidence" flag. Do not hide it, and do not draw a poor cluster as a confident placement.
- FR-25: Colour access point markers by placement confidence, not by the strongest RSSI. Tapping a marker shows confidence, reading count and spread. The 2D map and the 3D viewer today use one colour for every marker and show `max_rssi_dbm` in the detail text.

#### v1.1-6.2 Dead and weak zone layer

- FR-26: The 2D and 3D maps plot dead and weak (fair) areas as their own visible layer, so DTO can see those zones without only reading percentages. Cell classification stays as in FR-15 (good above -67 dBm, fair -67 to -80 dBm, dead below -80 dBm, thresholds configurable).

#### v1.1-6.3 Router coverage mode

This is a separate map mode from the strongest-signal heatmap and from a simple network-name count.

- FR-27: The mode counts each router (unique BSSID / device) in an area and lists the SSIDs that router broadcasts under it. One radio that serves both a staff and a guest name counts as one router.
- FR-28: The mode shows each selected router's coverage footprint on the map.
- FR-29: The mode traces chained or extended routers and highlights dead or weak gaps in the coverage between them.

#### v1.1-6.4 Admin view of surveyor work

- FR-30: Survey History shows the surveyor's name on each card. Admins can filter the list by surveyor. The API already accepts `surveyor_id` (admin-only); the app's `surveyPage` call does not send it.
- FR-31: The Users screen has a "View surveys" action that opens that surveyor's History.
- FR-32: Admins have a per-surveyor overview: survey count, a derived area (the buildings and outdoor extents they actually surveyed), and a way to open that surveyor's plot history. Do not add an assignments table. A combined map of one surveyor's walks uses the same consolidation as FR-34 once that exists.

#### v1.1-6.5 Campus map and consolidation

- FR-33: A campus or site can group several buildings and the outdoor areas between them, so DTO can open one map of that site (for example CMU).
- FR-34: Multiple processed surveys of buildings and outdoor areas on that campus can be selected and merged into one consolidated coverage map, one set of access point estimates, and the dead and weak layer (FR-26).
- FR-35: Outdoors, tag readings with a GPS position. Dead reckoning stays the indoor method (FR-8, FR-10); it is not relied on over long outdoor distances.

#### v1.1-6.6 AI analysis report

- FR-36: For a selected survey or a consolidated campus view, the API generates an AI-written analysis report with a summary of coverage (including dead and weak areas) and recommendations, which DTO can export (for example PDF or a shareable document, plus a text or Markdown original). v1.0 has no AI provider: coverage gap-filling is IDW, not a model (AGENTS.md, FR-13). The report is a new server-side call that uses one configured provider, with the API key in the existing secrets setup (CD-4), not in the repo.

#### v1.1-6.7 Web dashboard

- FR-37: A browser dashboard at `https://signalscape.boonbrigoli.site` (C-8) where a signed-in Admin can open the consolidated campus maps, the dead and weak layer, router coverage mode, and the analysis report on a larger screen. Reuse the existing Three.js viewer and the GeoJSON coverage where possible. Add a browser sign-in and a campus / building / survey picker; the current `/api/viewer` page does not have those. Role rules stay as in FR-2 and FR-3. This is not a Flutter web port of the survey app.

### v1.1-7. Technical stack (from v1.0)

No new C-ids. Course grading is done, but v1.1 keeps the v1.0 stack (Flutter app, FastAPI, PostgreSQL, Docker Compose, Caddy, JWT roles, OpenAPI at `/api/docs`, CI coverage gate, self-hosted runner, public HTTPS at `signalscape.boonbrigoli.site`). New API routes stay in the OpenAPI spec (C-10). Automated tests for the new estimator and routes run in CI (C-16, NFR-4).

### v1.1-8. Screens (v1.1 additions)

v1.0 already has the 12 screens in section 8 above, including Survey History and Admin user management. v1.1 adds or extends:

1. History: surveyor name on each card, and an admin surveyor filter (FR-30).
2. Users: "View surveys" (FR-31).
3. Per-surveyor overview, with a derived area (FR-32).
4. Dead and weak zone layer on the 2D and 3D maps (FR-26).
5. Router coverage mode on those maps (FR-27, FR-28, FR-29).
6. Campus or site map, with outdoor areas and consolidate controls (FR-33, FR-34, FR-35).
7. Analysis report view and export (FR-36).
8. Web dashboard: sign-in, campus picker, consolidated 2D and 3D maps, layers, report (FR-37).

### v1.1-9. Data privacy (RA 10173)

v1.0 rules stay: account data and the path a surveyor walked are personal data; consent before the first survey; HTTPS and role-based access; users can view, export and delete their data.

The campus map, outdoor GPS traces and the web dashboard mean a DTO admin may see several surveyors' walks, including outdoors, on one map. That is still limited to the Admin role (and to Viewers only for surveys shared with them). No new permission model is added. Surveys should still only be run where the user is allowed to. The analysis report may describe those walks and must not be exposed to anyone the underlying surveys would not be.

### v1.1-10. CI/CD pipeline

Unchanged from v1.0 (CI-1 to CI-9, CD-1 to CD-6). Add unit tests for the path-loss / best-fit estimator (including a case where the true position is outside the walked points, and a tight cluster that must show as low confidence) and integration tests for consolidation, the dead and weak layer, and router coverage. The AI provider key stays in GitHub Actions or server secrets, never in the repo (CD-4). Tag the v1.1 release when Boon asks; do not retag `v1.0`.

### v1.1-11. Non-functional requirements

v1.0 NFR-1 to NFR-4 stay.

- NFR-5: An access point estimate is not limited to the convex hull of the surveyor's readings. With enough spread, the marker may sit beyond the walked path.
- NFR-6: Campus-level consolidation of a typical DTO selection (several surveys, each up to a few thousand readings per floor) completes in under 30 seconds, in line with NFR-1.
- NFR-7: The web dashboard is usable in a current desktop browser at a typical office screen size (about 1280 px wide or more).

### v1.1-12. Known constraints and risks

- Indoor path-loss is approximate. The best-fit position will still be wrong if the walk never surrounds the router, or if almost every reading sits on one spot. The low-confidence flag is what marks those placements.
- Dead reckoning is not the main v1.1 fix. If, after FR-23 to FR-25, estimates still collapse because the phone recorded almost no steps, then run a short instrumented walk that logs step count against readings. That is a follow-up, not part of the 19 Nov slice.
- Android still throttles Wi-Fi scans; test phones should turn throttling off, as in v1.0.
- Outdoor GPS can still be several metres off, and may be worse near buildings. It is still better than dead reckoning over long outdoor distances. Indoor surveys keep the v1.0 start-fix and checkpoint rules.
- The 3D viewer is already a web page, but it only works when the app hands it a token and a survey id. The dashboard has to add browser sign-in and navigation without weakening that token handling.
- Consolidation has to define how overlapping walks are merged (for coverage, a combined IDW of all cleaned readings in the selection is the starting proposal) and how two surveys' estimates of the same BSSID are reduced to one marker.
- v1.0 has no AI provider. The report depends on one configured provider being available at runtime; if the key is missing, generation should fail clearly and leave export of the plotted layers and FR-19 figures intact.

### v1.1-13. Open questions

None remaining. Decisions are recorded in section 14.

### v1.1-14. Change log

Newest first. Times are Asia/Manila (UTC+8).

#### 2026-11-18
- 12:20: Approved plan copied from the drafts into this file and `IMPLEMENTATION.md` (branch `docs/v1.1-plan`). FR-14 is marked as replaced by FR-23.
- **Approved by Boon.** v1.1 is the DTO extended version; course grading is done. First slice (M9, M10) is due 19 Nov 2026.
- Access point placement (FR-23 to FR-25): path-loss plus best-fit; at least 5 readings spread over 3 m or more; below that, a faded marker with a "low confidence" flag (not hidden); colour by confidence.
- Dead and weak zones are plotted as their own map layer (FR-26).
- Router coverage is a separate mode (FR-27 to FR-29): count per router (BSSID), list SSIDs under each, show each footprint, and trace chained extenders to find dead gaps.
- No manual surveyor assignments and no assignments table. A surveyor's area is derived from what they surveyed (FR-30 to FR-32).
- DTO uses the existing Admin role; no new role.
- Consolidation is a campus or site map of several buildings plus outdoor areas, with GPS outdoors (FR-33 to FR-35).
- Analysis is the plotted dead and weak layer plus an AI-written, exportable report with summary and recommendations (FR-36). v1.0 gap-filling is IDW, not an AI model; the report uses one configured provider in the existing secrets setup.
- Web dashboard is hosted at `https://signalscape.boonbrigoli.site` (FR-37).
- Earlier draft open questions are closed. This approved plan replaces the pre-approval drafts.
