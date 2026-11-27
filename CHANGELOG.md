# Changelog

Notable changes to SignalScape, newest first. The first public release is 1.0.0. The git tag `v1.0` is added after the release pull request is merged, not in the pull request itself.

## Unreleased (v1.1 DTO extension)

- Campus sites that group buildings and an optional outdoor polygon, plus consolidation of selected surveys into one coverage map and one set of access point estimates.
- Outdoor survey capture that uses GPS positions instead of dead reckoning.
- AI-written Markdown analysis reports for a survey or a consolidated campus view, with the provider key in server secrets and figures still exportable when no provider is configured.
- Browser dashboard at the site root: sign-in, site/building/survey pickers, 2D and reused 3D maps with the dead and weak layer, router coverage and report export.
- Dashboard redesign: a choose, look, understand layout; a map you can pan, zoom and hover, with a legend, scale bar and one floor at a time; cascading pickers; shareable links; a readable report view; keyboard and screen reader support; loading, empty and error states. Fixes a Building picker that did nothing, unprocessed surveys that could be opened and failed, floors drawn on top of each other, and a campus merge that showed 0% good.
- Fixed the site-root redirect to `/api/dashboard/`: `redir` needs an explicit matcher, so the previous `redir /api/dashboard/` failed to load. CI now validates the Caddyfile.

## 1.0.0 - 2026-11-16

First feature-complete release of the API, the Flutter Android app and the docs. Boon tested the full flow on a real phone on 2026-11-16 and it was good.

### Accounts and access
- Register, sign in and consent, with JWT authentication
- Roles: Admin, Surveyor and Viewer
- Admin user management: list, search, change role, activate or deactivate, and delete
- Profile and settings: name, good and dead signal thresholds, change password, sign out and delete account

### Buildings, floors and surveys
- Buildings and floors, with optional floor-plan upload
- Survey capture on the phone: Wi-Fi RSSI, step and heading dead reckoning, barometer floor detection with a manual fallback, GPS checkpoints, offline storage and upload
- Live trail coloured by signal level, and a preview heatmap about every 60 seconds while online
- Processing: clean readings, inverse-distance-weighted coverage grid, access-point estimates, and good, fair and dead classification
- Survey history (list, filter, open, delete), survey summary, and CSV and GeoJSON export
- Delete a building, a floor or a survey, with a confirm dialog; an unfinished local survey of a deleted floor or building can be discarded

### Maps
- 2D map with a style picker (Mapbox satellite, light and dark, or OpenStreetMap when no token is set) and a network picker
- Smooth heatmap on the 2D map, the 3D view and the live preview: a continuous colour ramp from red at -30 dBm to dark blue at -100 dBm, soft edges, confidence as alpha, and contour lines every 5 dB
- 3D view (three.js) with stacked floors, a legend and layers panel, dead zones and estimated access points, and a 2D / 3D switch

### Operations
- CI and CD: GitHub Actions, branch protection on `main`, Docker Compose and Caddy deploy to https://signalscape.boonbrigoli.site
- Docs: design, user guide, API guide, local development, CI/CD, deployment, branching, config and secrets, and the runbook

### Versions
- Flutter app: `1.0.0+1` (already set; this is the version of the phone-tested APK)
- API: `1.0.0`

### Known limitations
- Tapping a position on the floor plan as a checkpoint is not built. Checkpoints use a GPS fix.
- There is no automated database backup. That work was left out of scope on 2026-11-16. The runbook has recommended manual dump and restore commands.
- Surveys processed before the smooth-heatmap and confidence work need Process run again, so their grids pick up the 5 m fill radius, per-cell confidence and the new display.
