# SignalScape

Map a building's Wi-Fi coverage in 3D with just an Android phone.

SignalScape is the ITSD 85 (Special Topics in Software Development) final project. A surveyor walks a building with the app. The phone records Wi-Fi signal strength while tracking its own position from step counting, gyroscope and compass, and it detects floor changes with the barometer. The API fills the gaps between readings with interpolation math, estimates where the access points are, and serves a 3D coverage map. Good, fair and dead zones show at a glance.

**Target users:** owners and facility managers of small and medium establishments (cafés, boarding houses, dormitories, clinics, small offices, schools) who need to find Wi-Fi dead zones and plan router placement but can't afford a professional site survey. **Pilot site:** our college, CISC, which has several known Wi-Fi dead zones; it will be surveyed for testing and the live demo.

## Features
- Building and floor setup with checkpoints that correct position drift
- Wi-Fi survey capture (RSSI) with indoor positioning and floor detection
- Coverage gap filling (inverse distance weighting or kriging) and access point location estimates
- Interactive 3D coverage view (Three.js)
- Role-based access: Admin and Surveyor (Viewer optional)
- Signal bands: good above -67 dBm, fair from -67 to -80 dBm, dead below -80 dBm

## Stack
| Part | Tech |
|---|---|
| Mobile app | Flutter (Android) with Three.js in a WebView |
| API | FastAPI, SQLAlchemy, Alembic, Pydantic, bcrypt, JWT, NumPy/SciPy |
| Database | PostgreSQL |
| Tests | pytest with pytest-cov, `flutter test` |
| Deploy | Docker Compose, Caddy (HTTPS), GitHub Actions with a self-hosted runner |

## Repo layout
```
signalscape/
├── api/                  # FastAPI backend
├── signalscape_mobile/   # Flutter Android app
├── .github/workflows/    # CI and CD
├── REQUIREMENTS.md       # What to build
├── IMPLEMENTATION.md     # Build order and progress
├── AGENTS.md             # Workflow rules for contributors and agents
└── README.md
```

## Getting started

### Prerequisites
- Docker and Docker Compose
- Python 3.12 (for running the API outside Docker)
- Flutter SDK and an Android device (Wi-Fi scanning doesn't work in the emulator)

### API
```bash
cd api
cp .env.example .env      # fill in the values
docker compose up -d      # starts the API and Postgres
```
- API docs: http://localhost:8000/api/docs
- Health check: http://localhost:8000/api/health

### Mobile app
```bash
cd signalscape_mobile
flutter pub get
flutter run               # with an Android phone connected
```
Point the app's API base URL at your running API.

### Tests
```bash
cd api && pytest --cov            # backend coverage must stay at 60% or more
cd signalscape_mobile && flutter test
```

## CI/CD
- **CI** runs on every push and pull request. It covers lint, tests with a Postgres container, the OpenAPI check, the Docker build, a dependency scan, `flutter analyze`, `flutter test` and the APK build.
- **CD** runs on every merge to `main`. A self-hosted runner on the server rebuilds the image, runs migrations, restarts with Docker Compose behind Caddy and smoke tests `/api/health`.
- The final release is tagged `v1.0`.

## Contributing
Read `AGENTS.md` first. In short, work through `IMPLEMENTATION.md` in order, use one branch per item, add tests with every change, open a pull request with passing CI, and tick the checkbox in the same pull request.

## Privacy
Built to comply with the Data Privacy Act of 2012 (RA 10173). Only account details and building scan data are stored, and secrets never go in the repo. See `REQUIREMENTS.md` for details.

## Author
Boon Jefferson Brigoli (solo project)
