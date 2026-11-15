import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../config.dart';
import '../core/dead_reckoning.dart';
import '../core/geo.dart';
import '../core/levels.dart';
import '../core/scan_throttle.dart';
import '../core/sync_engine.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../widgets/trail_view.dart';

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
  }) : floor = initialFloor;

  final ApiClient api;
  final LocalDb db;
  final SyncEngine engine;
  final Thresholds thresholds;
  final Building building;
  final List<Floor> floors;

  static const _uuid = Uuid();
  static const _stepsBetweenScans = 2;
  static const _maxScanGap = Duration(seconds: 30);

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
  int? latestRssi;
  double pulse = 0;
  final List<TrailPoint> trail = [];

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
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _changed();
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
      );
    } on ApiException catch (e) {
      error = e.message;
      _changed();
      return;
    }
    error = null;
    _originLat = f.lat;
    _originLng = f.lng;
    await _startSensors();
    phase = SurveyPhase.active;
    _changed();
  }

  Future<void> _startSensors() async {
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
      _changed();
    }
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

  void setFloor(Floor f) {
    floor = f;
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
        message = 'Android is limiting Wi-Fi scans; waiting a bit.';
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
      await db.add(SyncKind.readings, id, {
        'client_id': _uuid.v4(),
        'floor_id': floor.id,
        'lat': geo.lat,
        'lng': geo.lng,
        'bssid': bssid,
        'ssid': ap.ssid,
        'rssi_dbm': ap.level,
        'frequency_mhz': ap.frequency,
        'scanned_at': now.toIso8601String(),
      });
      readings++;
      if (strongest == null || ap.level > strongest) strongest = ap.level;
    }
    if (strongest != null) {
      latestRssi = strongest;
      pulse = 1;
      trail.add(
        TrailPoint(tracker.x, tracker.y, levelFor(strongest, thresholds)),
      );
      if (trail.length > 3000) trail.removeAt(0);
      message = null;
    }
    _changed();
    unawaited(_syncTick());
  }

  // --- checkpoint ---

  /// Marks "I am here". With a good GPS fix it also re-anchors the dead
  /// reckoned position to the fix, which removes the drift built up so far.
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
      tracker.reanchor(local.x, local.y);
      message =
          'Checkpoint saved. GPS ±${f.accuracyM.round()} m: position corrected.';
    } else {
      message = 'Checkpoint saved. No good GPS fix, so position was kept.';
    }
    _changed();
    unawaited(_syncTick());
  }

  // --- background work ---

  void _tick() {
    if (pulse > 0) pulse = (pulse - 0.12).clamp(0, 1);
    unawaited(_maybeScan());
    if (DateTime.now().second % 5 == 0) unawaited(_syncTick());
    _changed();
  }

  Future<void> _syncTick() async {
    if (_syncing || _disposed) return;
    _syncing = true;
    try {
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
      await engine.flushAll();
      await api.setSurveyStatus(id, 'completed');
      await api.process(id);
      phase = SurveyPhase.done;
      _changed();
      return true;
    } on SyncException catch (e) {
      error = 'Upload not finished: ${e.message}';
    } on ApiException catch (e) {
      error = e.message;
    }
    phase = SurveyPhase.endFailed;
    _changed();
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _gpsSub?.cancel();
    _accelSub?.cancel();
    _magSub?.cancel();
    _wifiSub?.cancel();
    _netSub?.cancel();
    super.dispose();
  }
}
