# API quick start

A short guide to calling the SignalScape REST API with `curl`: sign in, create a building, upload a survey, process it and read the results. The complete, always-current reference is the generated OpenAPI documentation:

- Live: https://signalscape.boonbrigoli.site/api/docs (Swagger UI), `/api/redoc`, and the raw schema at `/api/openapi.json`
- Locally: http://localhost:8000/api/docs (see [LOCAL_DEV.md](LOCAL_DEV.md))

Design background (tables, access rules, processing maths) is in [DESIGN.md](DESIGN.md); this page does not repeat it.

**The responses below are real.** They were captured on 2026-11-16 by running the API from `main` against a throwaway local database and calling it with the commands shown. IDs, e-mail addresses and the survey data are made up. Timestamps in your responses will carry the server's own clock and offset, and long arrays are shortened with `…`.

## Basics

- Base URL: `https://signalscape.boonbrigoli.site` (production). Every route starts with `/api`.
- Data is JSON, except the login form, the floor plan upload (multipart), the CSV export and the GeoJSON output.
- Authentication is a bearer JWT in the `Authorization` header. Tokens last 24 hours (`expires_in: 86400`).
- Errors are JSON with a `detail` field: a string (`401`, `403`, `404`, `409`) or a list of field problems (`422`).
- Lists are paged: `?page=1&page_size=20` (page size 1 to 100) and return `{"items": [...], "total": n, "page": 1, "page_size": 20}`. Sort with `?sort=field` or `?sort=-field` (descending); the allowed fields per endpoint are in `/api/docs`. Lists also take filters, for example `q` on buildings and `status`, `from`, `to`, `building_id` on surveys.
- IDs are UUIDs. BSSIDs are lower-case `aa:bb:cc:dd:ee:ff`.

Set this shell variable for the examples:

```bash
BASE=https://signalscape.boonbrigoli.site/api      # or http://localhost:8000/api
```

## Roles

| Role | Can do |
|---|---|
| Surveyor | New accounts get this role. Create and manage their own buildings, floors and surveys; process them. A Surveyor must record privacy consent before starting a survey. |
| Admin | Everything a Surveyor can do on anyone's data, plus user management (`/api/users`). The first admin is made with the command line tool (see [DEPLOYMENT.md](DEPLOYMENT.md)). |
| Viewer | Read-only. Sees only surveys that were shared with them (`/api/surveys/{id}/shares`), and no buildings list. Cannot process. |

Roles are enforced on the server.

## 1. Register and sign in

Register (always creates a Surveyor):

```bash
curl -sS -X POST $BASE/auth/register -H 'Content-Type: application/json' \
  -d '{"email":"surveyor@example.com","name":"Sam Surveyor","password":"correct-horse-1"}'
```

```json
{"id":"0314e219-9b9d-4f63-9850-acdd85ae5f0e","email":"surveyor@example.com","name":"Sam Surveyor","role":"surveyor","is_active":true,"consented_at":null,"good_threshold_dbm":-67,"dead_threshold_dbm":-80,"created_at":"2026-11-16T16:00:25.735654+08:00","updated_at":"2026-11-16T16:00:25.735654+08:00"}
```

The password needs at least 8 characters. A duplicate e-mail gives `409` ("Email is already registered"). Bad input gives `422`:

```json
{"detail":[{"type":"value_error","loc":["body","email"],"msg":"value is not a valid email address: An email address must have an @-sign.","input":"nope","ctx":{"reason":"An email address must have an @-sign."}},{"type":"string_too_short","loc":["body","name"],"msg":"String should have at least 1 character","input":"","ctx":{"min_length":1}},{"type":"string_too_short","loc":["body","password"],"msg":"String should have at least 8 characters","input":"short","ctx":{"min_length":8}}]}
```

Log in. This is an OAuth2 password form, so the e-mail goes in the field named `username` and the body is form-encoded, not JSON:

```bash
curl -sS -X POST $BASE/auth/login -d 'username=surveyor@example.com&password=correct-horse-1'
```

```json
{"access_token":"<jwt>","token_type":"bearer","expires_in":86400}
```

A wrong password or unknown e-mail gives `401` with `{"detail":"Incorrect email or password"}`. Keep the token in a variable (not in a file you commit):

```bash
TOKEN=<access_token from the response>
AUTH="Authorization: Bearer $TOKEN"
```

Who am I, and the privacy consent (a Surveyor must do this once before creating a survey; repeating it keeps the first timestamp):

```bash
curl -sS $BASE/auth/me -H "$AUTH"
curl -sS -X POST $BASE/auth/me/consent -H "$AUTH"
```

```json
{"id":"0314e219-…","email":"surveyor@example.com","name":"Sam Surveyor","role":"surveyor","is_active":true,"consented_at":"2026-11-16T16:00:25.832529+08:00","good_threshold_dbm":-67,"dead_threshold_dbm":-80,"created_at":"…","updated_at":"…"}
```

Without a token, any protected route answers `401` `{"detail":"Not authenticated"}`. A Surveyor calling an admin route (for example `GET /api/users`) gets `403` `{"detail":"You do not have permission to do this"}`.

`PATCH /api/auth/me` changes your name, password (needs `current_password`) or your own good and dead signal thresholds (`good_threshold_dbm`, `dead_threshold_dbm`, used when processing, default -67 and -80). `DELETE /api/auth/me` deletes your account and all of its data.

## 2. Buildings and floors

```bash
curl -sS -X POST $BASE/buildings -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"name":"CISC Building","address":"College campus"}'
```

```json
{"id":"2f994e14-5cd6-47f5-8e65-affe974d3fe0","owner_id":"0314e219-…","name":"CISC Building","address":"College campus","description":null,"created_at":"…","updated_at":"…"}
```

Add a floor (`level` 0 is ground, negative is a basement; `height_m` defaults to 3.0; `width_m` and `length_m` are optional). A second floor at the same level gives `409`.

```bash
BID=2f994e14-5cd6-47f5-8e65-affe974d3fe0
curl -sS -X POST $BASE/buildings/$BID/floors -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"level":0,"label":"Ground","height_m":3.2}'
```

```json
{"id":"9c978e73-9e30-4940-97e6-fe0de35d4c2b","building_id":"2f994e14-…","level":0,"label":"Ground","width_m":null,"length_m":null,"height_m":3.2,"created_at":"…","updated_at":"…","plan_url":null}
```

List buildings with search, sorting and paging:

```bash
curl -sS "$BASE/buildings?q=cisc&sort=-created_at&page=1&page_size=10" -H "$AUTH"
```

```json
{"items":[{"id":"2f994e14-…","owner_id":"0314e219-…","name":"CISC Building","address":"College campus","description":null,"created_at":"…","updated_at":"…"}],"total":1,"page":1,"page_size":10}
```

Other building and floor routes: `GET/PATCH/DELETE /api/buildings/{id}`, `GET /api/buildings/{id}/floors`, `PATCH/DELETE /api/floors/{id}`. Floor plan image (PNG or JPEG, at most 5 MB): `PUT /api/floors/{id}/plan` as multipart with the form field `file`, and `GET /api/floors/{id}/plan` to download it:

```bash
curl -sS -X PUT $BASE/floors/<floor-id>/plan -H "$AUTH" -F 'file=@plan.png;type=image/png'
```

## 3. Start a survey and upload data

The app does this for you; these calls show what it sends. Start a survey with the GPS start fix (accuracy must be 10 m or better) in one of your buildings:

```bash
curl -sS -X POST $BASE/surveys -H "$AUTH" -H 'Content-Type: application/json' -d '{
  "building_id":"2f994e14-5cd6-47f5-8e65-affe974d3fe0",
  "device_model":"Pixel 7","has_barometer":true,
  "origin_lat":14.5995,"origin_lng":120.9842,"origin_accuracy_m":6.5,"step_length_m":0.7}'
```

```json
{"id":"6b3db87d-a279-4204-b9e7-02ba6d8c6bf7","building_id":"2f994e14-…","surveyor_id":"0314e219-…","status":"active","started_at":"…","ended_at":null,"device_model":"Pixel 7","has_barometer":true,"origin_lat":14.5995,"origin_lng":120.9842,"origin_accuracy_m":6.5,"step_length_m":0.7,"notes":null,"processed_at":null,"created_at":"…","updated_at":"…"}
```

Upload readings (1 to 1000 per request). Each reading needs a `client_id` UUID that you generate. Sending the same `client_id` again is skipped, so retries are safe:

```bash
SID=6b3db87d-a279-4204-b9e7-02ba6d8c6bf7
curl -sS -X POST $BASE/surveys/$SID/readings -H "$AUTH" -H 'Content-Type: application/json' -d '{"readings":[
  {"client_id":"7d4c2a0e-5b1f-4c63-9a52-0f1d3e8b6a11","floor_id":"9c978e73-9e30-4940-97e6-fe0de35d4c2b",
   "lat":14.5995,"lng":120.9842,"accuracy_m":3.0,"bssid":"aa:bb:cc:dd:ee:01","ssid":"Lab-WiFi",
   "rssi_dbm":-45,"frequency_mhz":2437,"scanned_at":"2026-11-16T08:00:00+00:00"}]}'
```

```json
{"inserted":24,"skipped":0}
```

(24 was the count when the full example data set of 12 positions and 2 networks was sent.) The `ssid` is empty for hidden networks. `scanned_at` must include a time zone.

Checkpoints (positions fixed by GPS or tapped on the floor plan, used to correct drift):

```bash
curl -sS -X POST $BASE/surveys/$SID/checkpoints -H "$AUTH" -H 'Content-Type: application/json' -d '{"checkpoints":[
  {"client_id":"<uuid>","floor_id":"<floor-id>","lat":14.5995,"lng":120.98430,
   "estimated_lat":14.59950,"estimated_lng":120.98431,"source":"gps","recorded_at":"2026-11-16T08:01:00Z"}]}'
```

```json
{"inserted":1,"skipped":0}
```

Live preview while the survey is still running: a preview computes the heatmap and access points from what has been uploaded, returns them and saves nothing:

```bash
curl -sS -X POST "$BASE/surveys/$SID/process?preview=true" -H "$AUTH"
```

Finish the survey, then process it. A full run on a survey that is still `active` answers `409`:

```json
{"detail":"A active survey cannot be processed yet; complete it first, or use preview=true"}
```

```bash
curl -sS -X PATCH $BASE/surveys/$SID -H "$AUTH" -H 'Content-Type: application/json' -d '{"status":"completed"}'
curl -sS -X POST $BASE/surveys/$SID/process -H "$AUTH"
```

`status` can be `active`, `paused` or `completed`; `processed` is set by processing only. The process response (shortened):

```json
{"survey_id":"6b3db87d-…","status":"processed","preview":false,"computed_at":"…","thresholds":{"good_dbm":-67,"dead_dbm":-80},"floors":[{"floor_id":"9c978e73-…","floor_level":0,"floor_label":"Ground","floor_height_m":3.2,"raw_reading_count":24,"cleaned_reading_count":24,"area_covered_m2":11.0,"good_pct":100.0,"fair_pct":0.0,"dead_pct":0.0,"thresholds":{"good_dbm":-67,"dead_dbm":-80},"access_point_count":2}],"access_points":[{"floor_id":"9c978e73-…","floor_level":0,"bssid":"aa:bb:cc:dd:ee:01","ssid":"Lab-WiFi","frequency_mhz":2437,"lat":14.5995,"lng":120.98420895275206,"method":"weighted_centroid","reading_count":12,"max_rssi_dbm":-45},…],"grids":[]}
```

Processing again replaces the earlier results from the same readings (use this after the processing code changes, see [RUNBOOK.md](RUNBOOK.md)).

## 4. Read the results

All of these need a processed survey (except `trail`, `readings`, `checkpoints` and the CSV).

Summary per floor:

```bash
curl -sS $BASE/surveys/$SID/summary -H "$AUTH"
```

```json
{"survey_id":"6b3db87d-…","status":"processed","processed_at":"…","floors":[{"floor_id":"9c978e73-…","floor_level":0,"floor_label":"Ground","floor_height_m":3.2,"raw_reading_count":24,"cleaned_reading_count":24,"area_covered_m2":11.0,"good_pct":100.0,"fair_pct":0.0,"dead_pct":0.0,"thresholds":{"good_dbm":-67,"dead_dbm":-80},"access_point_count":2}]}
```

Networks seen (this feeds the network picker in the app and the 3D page):

```bash
curl -sS $BASE/surveys/$SID/networks -H "$AUTH"
```

```json
{"items":[{"ssid":"Lab-WiFi","bssid":"aa:bb:cc:dd:ee:01","reading_count":12,"max_rssi_dbm":-45},{"ssid":"Hallway-AP","bssid":"aa:bb:cc:dd:ee:02","reading_count":12,"max_rssi_dbm":-48}],"total":2,"page":1,"page_size":20}
```

Estimated access points (paged): `GET /api/surveys/{id}/access-points`.

Coverage grid of one floor. `values` is row-major, south row first, west column first, in dBm, `null` where there is no data. `origin_lat` and `origin_lng` are the south-west corner. Add `&bssid=aa:bb:cc:dd:ee:01` for one network instead of the strongest signal:

```bash
curl -sS "$BASE/surveys/$SID/coverage?floor_id=9c978e73-9e30-4940-97e6-fe0de35d4c2b" -H "$AUTH"
```

```json
{"survey_id":"6b3db87d-…","floor_id":"9c978e73-…","floor_level":0,"bssid":null,"method":"idw","cell_size_m":1.0,"origin_lat":14.5995,"origin_lng":120.9842,"cols":11,"rows":1,"values":[-47.7,-50.2,-52.9,-55.5,-57.7,-57.6,-56.1,-54.3,-52.5,-50.7,-49.1],"good_pct":100.0,"fair_pct":0.0,"dead_pct":0.0,"thresholds":{"good_dbm":-67,"dead_dbm":-80},"raw_reading_count":24,"cleaned_reading_count":24,"computed_at":"…"}
```

The walk, floor by floor (used by the app and the 3D page to draw the trail with start and end markers): `GET /api/surveys/{id}/trail`. Response (shortened):

```json
{"survey_id":"6b3db87d-…","start":{"floor_id":"9c978e73-…","floor_level":0,"lat":14.5995,"lng":120.9842,"at":"…","kind":"start"},"end":{"floor_id":"9c978e73-…","floor_level":0,"lat":14.5995,"lng":120.984299,"at":"…","kind":"reading"},"floors":[{"floor_id":"9c978e73-…","floor_level":0,"points":[…]}]}
```

GeoJSON for maps. One layer per floor through the `floor_level` property; `include` can be repeated with `cells`, `access_points` and `readings` (default: cells and access points); `floor_level` and `bssid` filter. The content type is `application/geo+json`:

```bash
curl -sS "$BASE/surveys/$SID/geojson?include=cells" -H "$AUTH"
```

```json
{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[120.9842,14.5995],[120.9842093,14.5995],[120.9842093,14.599509],[120.9842,14.599509],[120.9842,14.5995]]]},"properties":{"kind":"coverage","rssi_dbm":-47.7,"level":"good","floor_level":0,"bssid":null}},…]}
```

CSV export of all readings (a download with a file name like `survey-<id>.csv`):

```bash
curl -sS $BASE/surveys/$SID/export.csv -H "$AUTH" -o survey.csv
```

```csv
client_id,floor_level,lat,lng,accuracy_m,bssid,ssid,rssi_dbm,frequency_mhz,scanned_at
68ab7875-bc73-49e2-9ba4-4e551b745881,0,14.5995,120.9842,3.0,aa:bb:cc:dd:ee:01,Lab-WiFi,-45,2437,2026-11-16T08:00:00+00:00
…
```

Raw data: `GET /api/surveys/{id}/readings` and `/checkpoints` (paged).

Survey list with filters (`status`, `building_id`, `from`, `to`, and `surveyor_id` for admins):

```bash
curl -sS "$BASE/surveys?status=processed&page_size=5" -H "$AUTH"
```

## 5. Sharing with a Viewer

A Viewer account (an Admin can set a user's `role` to `viewer` with `PATCH /api/users/{id}`) sees only shared surveys. The survey owner shares one by e-mail (the e-mail must belong to an active Viewer, otherwise `404`; sharing twice gives `409`):

```bash
curl -sS -X POST $BASE/surveys/$SID/shares -H "$AUTH" -H 'Content-Type: application/json' -d '{"email":"viewer@example.com"}'
curl -sS $BASE/surveys/$SID/shares -H "$AUTH"                          # who can see it
curl -sS -X DELETE $BASE/surveys/$SID/shares/<user-id> -H "$AUTH"      # stop sharing
```

## 6. Admin: users

All under `/api/users`, admin only: `GET` (filters `role`, `is_active`, `q`; paging and sorting), `GET /{id}`, `PATCH /{id}` with `{"role": "...", "is_active": true|false}`, `DELETE /{id}`. The API refuses to delete, demote or deactivate the last active admin.

## 7. Health check and the 3D page

- `GET /api/health` needs no login and returns `{"status":"ok"}`, or `503` with `{"detail":"database unavailable"}`. The deploy smoke test uses it.
- The 3D page is a static page at `/api/viewer/`. The app opens it with `#survey=<id>&token=<jwt>` in the URL fragment, so the token is never sent to a server. The page reads data from the same API routes shown above (`summary`, `coverage`, `access-points`, `networks`, `trail`).

## Not verified

- The Viewer-share and admin user routes are described from the code and tests, not run against the live server for this page.
- Examples were run against a local copy of the API from `main`, not against production.
