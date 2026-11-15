# SignalScape app

Flutter (Android) app: sign in, pick a building and floor, then survey a floor with Wi-Fi scans, steps and compass heading. Everything is saved on the phone first and uploaded in the background. When you end the survey the API processes it and the 3D coverage page opens in a WebView.

## Run

```bash
cd app
flutter pub get
flutter run                                   # against https://signalscape.boonbrigoli.site
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # a local API from the emulator
```

Build an installable APK (point `API_BASE_URL` somewhere else only if needed):

```bash
flutter build apk --release
# app/build/app/outputs/flutter-apk/app-release.apk
```

Allow Location, Nearby devices and Physical activity when asked. Android allows about 4 Wi-Fi scans per 2 minutes while the app is in front, so the app starts a scan only when you have moved and the limit allows it. The screen stays on while the app is open.

## Check

```bash
flutter analyze
dart format --output=none --set-exit-if-changed .
flutter test
```

## Layout

- `lib/core/`: logic without Flutter or plugins (levels, geo projection, step and heading math, position tracking, scan throttle, sync engine). Unit tested.
- `lib/data/`: API client, token storage, local sqflite queue, session.
- `lib/survey/survey_controller.dart`: runs one survey (GPS, Wi-Fi, sensors, queue).
- `lib/screens/`, `lib/widgets/`: sign in, consent, pick, survey and 3D view screens.
- `lib/theme.dart`: the whole look (colors, type, buttons). Change it there.
