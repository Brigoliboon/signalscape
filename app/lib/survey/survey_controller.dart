import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../config.dart';
import '../core/barometer.dart';
import '../core/dead_reckoning.dart';
import '../core/drift.dart';
import '../core/geo.dart';
import '../core/levels.dart';
import '../core/preview.dart';
import '../core/scan_throttle.dart';
import '../core/sync_engine.dart';
import '../data/active_survey.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../widgets/trail_view.dart';
import 'finish.dart';
import 'gone_survey.dart';

enum SurveyPhase { acquiring, ready, active, paused, ending, endFailed, done }

class GpsFix {
  const GpsFix(this.lat, this.lng, this.accuracyM, this.at);

  final double lat;
  final double lng;
  final double accuracyM;
  final DateTime at;
}

/// Runs one survey on the phone: GPS start fix, Wi-Fi scans (within Android's
/// scan limit), steps and heading for dead reckoning, checkpoints, and the
/// offline queue that uploads everything in the background.
class SurveyController extends ChangeNotifier {
  SurveyController({
    required this.api,
    required this.db,
    required this.engine,
    required this.thresholds,
    required this.building,
    required this.floors,
    required Floor initialFloor,
    required this.userId,
    this.resumeFrom,
  }) : floor = initialFloor;

  final String userId;

  /// Set when the app was closed mid-survey and the person chose to resume.
  final ActiveSurvey? resumeFrom;

  final ApiClient api;
  final LocalDb db;
  final SyncEngine engine;
  final Thresholds thresholds;
  final Building building;
  final List<Floor> floors;

  static const _uuid = Uuid();
  static const _stepsBetweenScans = 2;
  static const _maxScanGap = Duration(seconds: 30);

  /// How often the live preview heatmap is refreshed while online.
  static const previewEvery = Duration(seconds: 60);

  /// Readings wait for a checkpoint to be drift-corrected, but not longer
  /// than this. After that they go up as they are.
  static const maxHold = Duration(minutes: 4);

  // --- what the screen shows ---
  SurveyPhase phase = SurveyPhase.acquiring;
  Floor floor;
  GpsFix? fix;
  String? surveyId;
  int readings = 0;
  int checkpoints = 0;
  int pending = 0;
  bool online = true;
  String? syncError;
  String? message;
  String? error;

  /// True when the last upload or complete failed with HTTP 404: the
  /// survey, or its floor or building, is gone on the server.
  bool surveyGone = false;
  int? latestRssi;
  double pulse = 0;
  final List<TrailPoint> trail = [];

  /// Every step of the walk, so the path stays drawn between Wi-Fi scans
  /// (Android only allows about four scans every two minutes).
  final List<PathPoint> path = [];

  /// Most breadcrumbs kept; the oldest go first.
  static const maxPath = 5000;

  /// The scan dots and the path on the floor being shown.
  List<TrailPoint> get trailHere => [
    for (final p in trail)
      if (p.floorId == floor.id) p,
  ];
  List<PathPoint> get pathHere => [
    for (final p in path)
      if (p.floorId == floor.id) p,
  ];

  // --- floors from the barometer (FR-9) ---
  /// Null until known; false means no barometer, so floors are picked by hand.
  bool? hasBarometer;

  /// When true the floor switches by itself on a detected change; otherwise it
  /// is only suggested. Either way a manual pick always wins.
  bool autoSwitchFloors = false;

  /// A floor the barometer thinks the person is on, waiting for a tap.
  Floor? suggestion;

  // --- drift correction (FR-10) ---
  int held = 0;

  // --- live preview heatmap (FR-11a) ---
  PreviewGrid? preview;
  DateTime? previewAt;
  bool previewStale = false;

  final ScanThrottle throttle = ScanThrottle();
  final PositionTracker tracker = PositionTracker();
  final HeadingFilter _heading = HeadingFilter();
  final StepDetector _stepper = StepDetector();

  double? get heading => _heading.heading;
  int get steps => tracker.steps;
  bool get gpsGoodEnough => fix != null && fix!.accuracyM <= maxStartAccuracyM;
  bool get collecting => phase == SurveyPhase.active;
  Duration get nextScanIn => throttle.waitFor(DateTime.now());
  int get scansUsed => throttle.usedIn(DateTime.now());

  // --- internals ---
  double _originLat = 0;
  double _originLng = 0;
  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<List<WiFiAccessPoint>>? _wifiSub;
  StreamSubscription<List<ConnectivityResult>>? _netSub;
  Timer? _timer;
  AccelerometerEvent? _lastAccel;
  final Map<String, String> _lastSeen = {};
  int _stepsAtLastScan = 0;
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _scanning = false;
  bool _syncing = false;
  bool _netUp = true;
  int _syncFailures = 0;
  DateTime _nextSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;
  StreamSubscription<BarometerEvent>? _baroSub;
  BarometerFloorTracker? _baro;
  Timer? _baroCheck;
  int _cpSteps = 0;
  bool _previewBusy = false;
  DateTime _nextPreviewAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _saveCounter = 0;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Asks for permissions and starts watching GPS, the network and the queue.
  Future<void> init() async {
    final granted = await [
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
      Permission.activityRecognition,
    ].request();
    if (!(granted[Permission.locationWhenInUse]?.isGranted ?? false)) {
      error = 'Location permission is needed to scan Wi-Fi and get a GPS fix.';
      _changed();
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      error = 'Turn on Location in the phone settings, then come back.';
      _changed();
      return;
    }
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 0,
          ),
        ).listen(
          (p) {
            fix = GpsFix(p.latitude, p.longitude, p.accuracy, DateTime.now());
            if (phase == SurveyPhase.acquiring) phase = SurveyPhase.ready;
            _changed();
          },
          onError: (Object e) {
            error = 'GPS error: $e';
            _changed();
          },
        );
    _netSub = Connectivity().onConnectivityChanged.listen((results) {
      _netUp = !results.contains(ConnectivityResult.none);
      if (_netUp) _nextSyncAt = DateTime.fromMillisecondsSinceEpoch(0);
      online = _netUp && _syncFailures == 0;
      _changed();
    });
    _watchBarometer();
    final r = resumeFrom;
    if (r != null) await _resume(r);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _changed();
  }

  /// Picks up a survey the app lost when it was closed. It comes back paused,
  /// at the last position it knew; a checkpoint with a good GPS fix puts it
  /// right if the person moved in the meantime.
  Future<void> _resume(ActiveSurvey r) async {
    surveyId = r.surveyId;
    _originLat = r.originLat;
    _originLng = r.originLng;
    tracker
      ..x = r.x
      ..y = r.y
      ..steps = r.steps;
    _cpSteps = r.steps;
    _crumb();
    readings = await db.readingCount(r.surveyId);
    checkpoints = r.checkpoints;
    // Readings held before the app closed can no longer be corrected.
    await db.releaseHeld(r.surveyId);
    await _startSensors();
    phase = SurveyPhase.paused;
    message =
        'Survey resumed. Stand where you are on the map, add a checkpoint '
        'to re-sync your position, then press Resume.';
    unawaited(_tryStatus('paused'));
  }

  // --- barometer ---

  void _watchBarometer() {
    try {
      _baroSub = barometerEventStream(
        samplingPeriod: const Duration(milliseconds: 250),
      ).listen(_onBaro, onError: (Object _) => _noBarometer());
    } catch (_) {
      _noBarometer();
      return;
    }
    // A phone without a barometer never sends an event.
    _baroCheck = Timer(const Duration(seconds: 4), () {
      if (hasBarometer == null) _noBarometer();
    });
  }

  void _noBarometer() {
    if (hasBarometer == true) return;
    hasBarometer = false;
    _changed();
  }

  FloorStack get _stack => FloorStack(
    levels: [for (final f in floors) f.level],
    heights: {for (final f in floors) f.level: f.heightM},
  );

  void _onBaro(BarometerEvent e) {
    if (hasBarometer != true) {
      hasBarometer = true;
      _changed();
    }
    final baro = _baro;
    if (baro == null || !(collecting || phase == SurveyPhase.paused)) return;
    final level = baro.feed(DateTime.now().millisecondsSinceEpoch, e.pressure);
    if (level == null) return;
    onFloorDetected(level);
  }

  /// Called when the barometer settles on a different floor [level].
  @visibleForTesting
  void onFloorDetected(int level) {
    final detected = floors.where((f) => f.level == level);
    if (detected.isEmpty) return;
    final f = detected.first;
    if (f.id == floor.id) {
      suggestion = null;
    } else if (autoSwitchFloors) {
      _applyFloor(f);
      message = 'Switched to ${f.label} (barometer).';
    } else {
      suggestion = f;
      message = 'Looks like you are on ${f.label}. Tap Switch to confirm.';
    }
    _changed();
  }

  void setAutoSwitch(bool value) {
    autoSwitchFloors = value;
    final s = suggestion;
    if (value && s != null) {
      _applyFloor(s);
      message = 'Switched to ${s.label} (barometer).';
    }
    _changed();
  }

  void acceptSuggestion() {
    final s = suggestion;
    if (s == null) return;
    _applyFloor(s);
    _changed();
  }

  void dismissSuggestion() {
    suggestion = null;
    _changed();
  }

  void _applyFloor(Floor f) {
    floor = f;
    suggestion = null;
    _nextPreviewAt = DateTime.now();
    _crumb();
    _saveActive();
  }

  // --- start, pause, resume ---

  Future<void> start() async {
    final f = fix;
    if (f == null || f.accuracyM > maxStartAccuracyM) {
      message = 'Wait for a GPS fix of $maxStartAccuracyM m or better.';
      _changed();
      return;
    }
    try {
      message = null;
      surveyId = await api.createSurvey(
        buildingId: building.id,
        originLat: f.lat,
        originLng: f.lng,
        originAccuracyM: f.accuracyM,
        deviceModel: 'Android',
        hasBarometer: hasBarometer == true,
      );
    } on ApiException catch (e) {
      error = e.message;
      _changed();
      return;
    }
    error = null;
    _originLat = f.lat;
    _originLng = f.lng;
    _cpSteps = 0;
    _crumb();
    await _startSensors();
    phase = SurveyPhase.active;
    await _saveActive();
    _changed();
  }

  Future<void> _saveActive() async {
    final id = surveyId;
    if (id == null || phase == SurveyPhase.done) return;
    try {
      await db.saveActive(
        ActiveSurvey(
          surveyId: id,
          userId: userId,
          buildingId: building.id,
          buildingName: building.name,
          floorId: floor.id,
          originLat: _originLat,
          originLng: _originLng,
          x: tracker.x,
          y: tracker.y,
          steps: tracker.steps,
          checkpointSteps: _cpSteps,
          startedMs:
              resumeFrom?.startedMs ?? DateTime.now().millisecondsSinceEpoch,
          readings: readings,
          checkpoints: checkpoints,
        ),
      );
    } catch (_) {
      // Only the resume note is lost; the readings themselves are safe.
    }
  }

  Future<void> _startSensors() async {
    // Calibrates on the floor the survey starts (or resumes) on.
    if (hasBarometer != false && _baro == null) {
      _baro = BarometerFloorTracker(stack: _stack)..calibrate(floor.level);
    }
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.gameInterval,
    ).listen(_onAccel);
    _magSub = magnetometerEventStream(
      samplingPeriod: SensorInterval.uiInterval,
    ).listen(_onMag);
    final can = await WiFiScan.instance.canGetScannedResults(
      askPermissions: false,
    );
    if (can == CanGetScannedResults.yes) {
      _wifiSub = WiFiScan.instance.onScannedResultsAvailable.listen(_onResults);
    } else {
      message = 'Wi-Fi results are not available ($can).';
    }
  }

  void _onAccel(AccelerometerEvent e) {
    _lastAccel = e;
    if (!collecting) return;
    final stepped = _stepper.feed(
      DateTime.now().millisecondsSinceEpoch,
      e.x,
      e.y,
      e.z,
    );
    final h = _heading.heading;
    if (stepped && h != null) {
      tracker.step(h);
      _crumb();
      _changed();
    }
  }

  /// Adds the current position to the path, on the floor being shown.
  void _crumb() {
    path.add(
      PathPoint(tracker.x, tracker.y, tracker.steps.toDouble(), floor.id),
    );
    if (path.length > maxPath) path.removeAt(0);
  }

  void _onMag(MagnetometerEvent e) {
    final a = _lastAccel;
    if (a == null) return;
    final h = headingFromSensors(a.x, a.y, a.z, e.x, e.y, e.z);
    if (h != null) _heading.update(h);
  }

  Future<void> pause() async {
    if (phase != SurveyPhase.active) return;
    phase = SurveyPhase.paused;
    _changed();
    await _tryStatus('paused');
  }

  Future<void> resume() async {
    if (phase != SurveyPhase.paused) return;
    phase = SurveyPhase.active;
    _changed();
    await _tryStatus('active');
  }

  /// The local state wins; the server is told when it can be reached.
  Future<void> _tryStatus(String status) async {
    try {
      await api.setSurveyStatus(surveyId!, status);
    } on ApiException {
      // Completed at the end anyway, which works from either state.
    }
  }

  /// A manual pick. It wins over the barometer, which re-bases on this floor.
  void setFloor(Floor f) {
    floor = f;
    suggestion = null;
    _baro?.confirm(f.level);
    _nextPreviewAt = DateTime.now();
    _crumb();
    _saveActive();
    _changed();
  }

  // --- Wi-Fi ---

  Future<void> _maybeScan() async {
    if (!collecting || _scanning) return;
    final now = DateTime.now();
    if (!throttle.canScan(now)) return;
    final moved = steps - _stepsAtLastScan >= _stepsBetweenScans;
    final stale = now.difference(_lastScanAt) >= _maxScanGap;
    if (!moved && !stale) return;
    _scanning = true;
    try {
      final can = await WiFiScan.instance.canStartScan(askPermissions: false);
      final ok = can == CanStartScan.yes && await WiFiScan.instance.startScan();
      if (ok) {
        throttle.recordStart(now);
        _stepsAtLastScan = steps;
        _lastScanAt = now;
      } else {
        throttle.recordRefusal(now);
        message =
            'Android is limiting Wi-Fi scans; waiting a bit. Turning off '
            '"Wi-Fi scan throttling" in Developer options allows more.';
      }
    } finally {
      _scanning = false;
    }
  }

  Future<void> _onResults(List<WiFiAccessPoint> aps) async {
    if (!collecting || surveyId == null) return;
    final id = surveyId!;
    final now = DateTime.now().toUtc();
    final geo = toGeo(tracker.x, tracker.y, _originLat, _originLng);
    int? strongest;
    for (final ap in aps) {
      if (ap.frequency < 2400 || ap.frequency > 7200) continue;
      if (ap.level > 0 || ap.level < -120) continue;
      if (ap.ssid.length > 32 || ap.ssid.contains('\u0000')) continue;
      final key =
          ap.timestamp?.toString() ?? '${now.millisecondsSinceEpoch ~/ 5000}';
      final bssid = ap.bssid.toLowerCase();
      if (_lastSeen[bssid] == key) continue;
      _lastSeen[bssid] = key;
      await db.add(
        SyncKind.readings,
        id,
        {
          'client_id': _uuid.v4(),
          'floor_id': floor.id,
          'lat': geo.lat,
          'lng': geo.lng,
          'bssid': bssid,
          'ssid': ap.ssid,
          'rssi_dbm': ap.level,
          'frequency_mhz': ap.frequency,
          'scanned_at': now.toIso8601String(),
        },
        x: tracker.x,
        y: tracker.y,
        progress: steps.toDouble(),
      );
      readings++;
      if (strongest == null || ap.level > strongest) strongest = ap.level;
    }
    if (strongest != null) {
      latestRssi = strongest;
      pulse = 1;
      trail.add(
        TrailPoint(
          tracker.x,
          tracker.y,
          levelFor(strongest, thresholds),
          steps.toDouble(),
          floor.id,
        ),
      );
      if (trail.length > 3000) trail.removeAt(0);
      message = null;
    }
    _changed();
    unawaited(_syncTick());
  }

  // --- checkpoint ---

  /// Marks "I am here". With a good GPS fix it also re-anchors the dead
  /// reckoned position to the fix, and the error found is spread back over
  /// the readings taken since the last checkpoint, before they are uploaded
  /// (FR-10). Without a good fix the checkpoint is only a marker.
  Future<void> checkpoint() async {
    final id = surveyId;
    if (id == null || !(collecting || phase == SurveyPhase.paused)) return;
    final est = toGeo(tracker.x, tracker.y, _originLat, _originLng);
    final f = fix;
    final good =
        f != null &&
        f.accuracyM <= maxStartAccuracyM &&
        DateTime.now().difference(f.at) < const Duration(seconds: 10);
    final actualLat = good ? f.lat : est.lat;
    final actualLng = good ? f.lng : est.lng;
    await db.add(SyncKind.checkpoints, id, {
      'client_id': _uuid.v4(),
      'floor_id': floor.id,
      'lat': actualLat,
      'lng': actualLng,
      'estimated_lat': est.lat,
      'estimated_lng': est.lng,
      'source': good ? 'gps' : 'tap',
      'recorded_at': DateTime.now().toUtc().toIso8601String(),
    });
    checkpoints++;
    if (good) {
      final local = toLocal(f.lat, f.lng, _originLat, _originLng);
      final errX = local.x - tracker.x;
      final errY = local.y - tracker.y;
      final end = steps.toDouble();
      final fixed = await db.applyCorrection(
        id,
        errX: errX,
        errY: errY,
        startProgress: _cpSteps.toDouble(),
        endProgress: end,
        originLat: _originLat,
        originLng: _originLng,
      );
      _correctTrail(errX, errY, end);
      tracker.reanchor(local.x, local.y);
      _cpSteps = steps;
      final off = math.sqrt(errX * errX + errY * errY);
      message =
          'Checkpoint saved. GPS ±${f.accuracyM.round()} m. Position was '
          '${off.toStringAsFixed(1)} m off; $fixed readings corrected.';
    } else {
      message =
          'Checkpoint saved. No good GPS fix, so the position was kept and '
          'no drift was corrected.';
    }
    held = await db.heldCount(id);
    await _saveActive();
    _changed();
    unawaited(_syncTick());
  }

  void _correctTrail(double errX, double errY, double end) {
    final fixed = spreadDrift(
      [for (final p in trail) DriftPoint(p.x, p.y, p.progress)],
      errX,
      errY,
      startProgress: _cpSteps.toDouble(),
      endProgress: end,
    );
    for (var i = 0; i < trail.length; i++) {
      trail[i] = TrailPoint(
        fixed[i].x,
        fixed[i].y,
        trail[i].level,
        trail[i].progress,
        trail[i].floorId,
      );
    }
    final fixedPath = spreadDrift(
      [for (final p in path) DriftPoint(p.x, p.y, p.progress)],
      errX,
      errY,
      startProgress: _cpSteps.toDouble(),
      endProgress: end,
    );
    for (var i = 0; i < path.length; i++) {
      path[i] = PathPoint(
        fixedPath[i].x,
        fixedPath[i].y,
        path[i].progress,
        path[i].floorId,
      );
    }
  }

  // --- background work ---

  void _tick() {
    if (pulse > 0) pulse = (pulse - 0.12).clamp(0, 1);
    unawaited(_maybeScan());
    if (DateTime.now().second % 5 == 0) unawaited(_syncTick());
    unawaited(previewTick());
    if (++_saveCounter % 10 == 0) unawaited(_saveActive());
    _changed();
  }

  // --- live preview heatmap (FR-11a) ---

  /// About once a minute, while online, asks the API to process what it has
  /// for the current floor and keeps the strongest-signal grid to draw under
  /// the trail. Nothing is saved on the server, and failures stay quiet: the
  /// last grid stays on screen and is marked as old.
  @visibleForTesting
  Future<void> previewTick() async {
    final id = surveyId;
    if (id == null || _previewBusy || _disposed) return;
    if (!(collecting || phase == SurveyPhase.paused)) return;
    final now = DateTime.now();
    if (now.isBefore(_nextPreviewAt)) return;
    if (!_netUp) {
      if (preview != null && !previewStale) {
        previewStale = true;
        _changed();
      }
      return;
    }
    _previewBusy = true;
    _nextPreviewAt = now.add(previewEvery);
    final floorId = floor.id;
    try {
      final json = await api.processPreview(id, floorId);
      if (_disposed) return;
      final grid = pickPreviewGrid(
        json,
        floorId,
        originLat: _originLat,
        originLng: _originLng,
      );
      // Keep showing the old grid if this answer has nothing in it yet.
      if (grid != null && grid.filledCells > 0) preview = grid;
      previewAt = DateTime.now();
      previewStale = false;
    } on ApiException {
      previewStale = preview != null;
    } catch (_) {
      previewStale = preview != null;
    } finally {
      _previewBusy = false;
      _changed();
    }
  }

  Future<void> _syncTick() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    try {
      final id = surveyId;
      if (id != null && phase != SurveyPhase.ending) {
        // Readings that waited too long for a checkpoint go up as they are.
        await db.releaseHeld(id, olderThan: maxHold);
        held = await db.heldCount(id);
      }
      pending = await db.pendingCount();
      if (pending == 0) {
        _syncFailures = 0;
        syncError = null;
        online = _netUp;
        return;
      }
      if (DateTime.now().isBefore(_nextSyncAt)) return;
      final result = await engine.pump();
      if (result.ok) {
        _syncFailures = 0;
        syncError = null;
        online = _netUp;
      } else {
        final e = result.error!;
        _syncFailures++;
        syncError = e.message;
        online = false;
        if (e.isGone) {
          surveyGone = true;
          error = localSurveyGoneMessage;
        }
        // A retryable failure waits 5 s, 10 s, 30 s, then 2 min. Anything else
        // needs a person, so the engine pauses for the longest wait.
        _nextSyncAt = DateTime.now().add(
          SyncEngine.backoffFor(e.retryable ? _syncFailures : 99),
        );
      }
      pending = await db.pendingCount();
    } finally {
      _syncing = false;
      _changed();
    }
  }

  // --- end ---

  /// Stops collecting, uploads what is left, completes and processes the
  /// survey. On failure the survey stays on the phone and [end] can be retried.
  Future<bool> end() async {
    final id = surveyId;
    if (id == null) return false;
    phase = SurveyPhase.ending;
    error = null;
    _changed();
    try {
      // No more checkpoints are coming, so held readings are released.
      held = 0;
      await finishSurvey(api: api, db: db, engine: engine, surveyId: id);
      phase = SurveyPhase.done;
      surveyGone = false;
      _changed();
      return true;
    } on SyncException catch (e) {
      if (e.isGone) {
        surveyGone = true;
        error = localSurveyGoneMessage;
      } else {
        surveyGone = false;
        error = 'Upload not finished: ${e.message}';
      }
    } on ApiException catch (e) {
      if (isGoneStatus(e.statusCode)) {
        surveyGone = true;
        error = localSurveyGoneMessage;
      } else {
        surveyGone = false;
        error = e.message;
      }
    }
    phase = SurveyPhase.endFailed;
    _changed();
    return false;
  }

  /// Forgets this survey's local readings and the resume note after the
  /// floor, building or survey was deleted on the server.
  Future<void> discardLocal() async {
    final id = surveyId;
    if (id == null) return;
    await db.discardSurvey(id);
    surveyGone = false;
    error = null;
    syncError = null;
    phase = SurveyPhase.done;
    _changed();
  }

  @override
  void dispose() {
    unawaited(_saveActive());
    _disposed = true;
    _timer?.cancel();
    _baroCheck?.cancel();
    _baroSub?.cancel();
    _gpsSub?.cancel();
    _accelSub?.cancel();
    _magSub?.cancel();
    _wifiSub?.cancel();
    _netSub?.cancel();
    super.dispose();
  }
}
