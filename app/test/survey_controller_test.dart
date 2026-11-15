import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/config.dart';
import 'package:signalscape_mobile/core/geo.dart';
import 'package:signalscape_mobile/core/levels.dart';
import 'package:signalscape_mobile/core/sync_engine.dart';
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/api_client.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/models.dart';
import 'package:signalscape_mobile/survey/survey_controller.dart';
import 'package:signalscape_mobile/widgets/trail_view.dart';

import 'support.dart';

const f0 = Floor(id: 'f0', level: 0, label: 'Ground', heightM: 3.2);
const f1 = Floor(id: 'f1', level: 1, label: 'First', heightM: 3.2);

Map<String, dynamic> reading(String id, double x, double y) {
  final g = toGeo(x, y, 0, 0);
  return {'client_id': id, 'lat': g.lat, 'lng': g.lng, 'rssi_dbm': -60};
}

void main() {
  setUpAll(useFfiSqlite);

  late LocalDb db;
  late List<http.Request> calls;
  late Map<String, http.Response Function(http.Request)> routes;
  late SurveyController c;

  setUp(() async {
    db = await memoryDb();
    calls = [];
    routes = {};
    final api = apiFor((req) async {
      calls.add(req);
      final r = routes['${req.method} ${req.url.path}'];
      return r == null ? jsonResponse({}) : r(req);
    });
    c = SurveyController(
      api: api,
      db: db,
      engine: SyncEngine(
        store: db,
        transport: ApiSyncTransport(api),
        batchSize: syncBatchSize,
      ),
      thresholds: const Thresholds(),
      building: const Building(id: 'b1', name: 'Main'),
      floors: const [f0, f1],
      initialFloor: f0,
      userId: 'u1',
    )..surveyId = 's1';
  });

  tearDown(() async {
    c.dispose();
    // Let the background sync and save that checkpoint() starts finish.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await db.close();
  });

  group('floor detection (FR-9)', () {
    test('suggests the detected floor and waits for a tap', () {
      c.onFloorDetected(1);
      expect(c.floor, f0);
      expect(c.suggestion, f1);
      c.acceptSuggestion();
      expect(c.floor, f1);
      expect(c.suggestion, isNull);
    });

    test('auto-switch changes floor straight away', () {
      c.autoSwitchFloors = true;
      c.onFloorDetected(1);
      expect(c.floor, f1);
      expect(c.suggestion, isNull);
      expect(c.message, contains('First'));
    });

    test('turning auto-switch on applies a waiting suggestion', () {
      c.onFloorDetected(1);
      c.setAutoSwitch(true);
      expect(c.floor, f1);
      expect(c.suggestion, isNull);
    });

    test('ignore drops the suggestion and keeps the floor', () {
      c.onFloorDetected(1);
      c.dismissSuggestion();
      expect(c.suggestion, isNull);
      expect(c.floor, f0);
    });

    test('a manual pick wins and clears any suggestion', () {
      c.onFloorDetected(1);
      c.setFloor(f0);
      expect(c.suggestion, isNull);
      expect(c.floor, f0);
    });

    test('a level the building does not have is ignored', () {
      c.onFloorDetected(7);
      expect(c.suggestion, isNull);
      expect(c.floor, f0);
    });

    test('detecting the current floor again clears a stale suggestion', () {
      c.onFloorDetected(1);
      c.onFloorDetected(0);
      expect(c.suggestion, isNull);
    });
  });

  group('walk path', () {
    test('a floor change starts the path on the new floor', () {
      c.tracker
        ..x = 3
        ..y = 4
        ..steps = 6;
      c.setFloor(f1);
      expect(c.path.single.floorId, 'f1');
      expect(c.path.single.x, 3);
      expect(c.path.single.progress, 6);
      c.onFloorDetected(0);
      c.autoSwitchFloors = true;
      c.onFloorDetected(0);
      expect(c.floor, f0);
      expect(c.path.map((p) => p.floorId), ['f1', 'f0']);
    });

    test('only the shown floor is drawn', () {
      c.trail
        ..add(const TrailPoint(0, 0, SignalLevel.good, 0, 'f0'))
        ..add(const TrailPoint(1, 0, SignalLevel.good, 1, 'f1'));
      c.path
        ..add(const PathPoint(0, 0, 0, 'f0'))
        ..add(const PathPoint(1, 0, 1, 'f1'))
        ..add(const PathPoint(2, 0, 2, 'f0'));
      expect(c.trailHere.single.floorId, 'f0');
      expect(c.pathHere.map((p) => p.x), [0, 2]);
    });

    test('a good GPS fix bends the path too, ending on the fix', () async {
      c.phase = SurveyPhase.active;
      c.path
        ..add(const PathPoint(0, 0, 0))
        ..add(const PathPoint(5, 0, 5))
        ..add(const PathPoint(10, 0, 10));
      c.tracker
        ..x = 10
        ..steps = 10;
      final g = toGeo(10, 2, 0, 0);
      c.fix = GpsFix(g.lat, g.lng, 5, DateTime.now());
      await c.checkpoint();
      expect(c.path.first.y, closeTo(0, 1e-9));
      expect(c.path[1].y, closeTo(1, 1e-9));
      expect(c.path.last.y, closeTo(2, 1e-9));
    });
  });

  group('checkpoint drift correction (FR-10)', () {
    Future<void> hold(String id, double x, double y, double progress) => db.add(
      SyncKind.readings,
      's1',
      reading(id, x, y),
      x: x,
      y: y,
      progress: progress,
    );

    GpsFix fixAt(
      double x,
      double y, {
      double acc = 5,
      Duration age = Duration.zero,
    }) {
      final g = toGeo(x, y, 0, 0);
      return GpsFix(g.lat, g.lng, acc, DateTime.now().subtract(age));
    }

    test(
      'a good GPS fix corrects held readings, the trail and the position',
      () async {
        c.phase = SurveyPhase.active;
        await hold('a', 0, 0, 0);
        await hold('b', 5, 0, 5);
        await hold('c', 10, 0, 10);
        c.trail
          ..add(const TrailPoint(0, 0, SignalLevel.good, 0))
          ..add(const TrailPoint(10, 0, SignalLevel.good, 10));
        c.tracker
          ..x = 10
          ..y = 0
          ..steps = 10;
        c.fix = fixAt(10, 2);

        await c.checkpoint();

        expect(c.tracker.x, closeTo(10, 1e-3));
        expect(c.tracker.y, closeTo(2, 1e-3));
        expect(c.trail.first.y, closeTo(0, 1e-9));
        expect(c.trail.last.y, closeTo(2, 1e-9));
        expect(c.held, 0);
        expect(c.checkpoints, 1);
        expect(c.message, contains('3 readings corrected'));
      },
    );

    test('the corrected readings go up with moved positions', () async {
      c.phase = SurveyPhase.active;
      await hold('a', 0, 0, 0);
      await hold('b', 10, 0, 10);
      c.tracker
        ..x = 10
        ..steps = 10;
      c.fix = fixAt(10, 4);
      await c.checkpoint();
      // The checkpoint itself goes first, then the readings.
      final cp = (await db.nextBatch(100))!;
      expect(cp.kind, SyncKind.checkpoints);
      expect(cp.items.single['source'], 'gps');
      await db.markSynced(cp);
      final batch = (await db.nextBatch(100))!;
      final y = {
        for (final r in batch.items)
          r['client_id']: toLocal(
            r['lat'] as double,
            r['lng'] as double,
            0,
            0,
          ).y,
      };
      expect(y['a'], closeTo(0, 1e-3));
      expect(y['b'], closeTo(4, 1e-3));
    });

    test('a tap checkpoint without a good fix changes nothing', () async {
      c.phase = SurveyPhase.active;
      await hold('a', 0, 0, 0);
      c.tracker
        ..x = 3
        ..steps = 4;
      c.fix = fixAt(50, 50, acc: 40); // too inaccurate
      await c.checkpoint();
      expect(c.tracker.x, 3);
      expect(c.held, 1);
      expect(await db.heldCount('s1'), 1);
      expect(c.message, contains('No good GPS fix'));
      final cp = (await db.nextBatch(10))!;
      expect(cp.items.single['source'], 'tap');
    });

    test('an old fix is not used', () async {
      c.phase = SurveyPhase.active;
      c.tracker.x = 3;
      c.fix = fixAt(50, 50, age: const Duration(seconds: 30));
      await c.checkpoint();
      expect(c.tracker.x, 3);
    });

    test('nothing happens when no survey is running', () async {
      c.phase = SurveyPhase.ready;
      await c.checkpoint();
      expect(c.checkpoints, 0);
    });

    test('the unfinished-survey note is kept up to date', () async {
      c.phase = SurveyPhase.active;
      c.tracker
        ..x = 1
        ..y = 2
        ..steps = 7;
      c.fix = fixAt(1, 2);
      await c.checkpoint();
      final a = (await db.activeFor('u1'))!;
      expect(a.surveyId, 's1');
      expect(a.buildingName, 'Main');
      expect(a.checkpoints, 1);
      expect(a.checkpointSteps, 7);
    });
  });

  group('ending', () {
    test(
      'releases held readings, uploads, completes, processes, forgets',
      () async {
        c.phase = SurveyPhase.active;
        await db.add(SyncKind.readings, 's1', reading('a', 0, 0), x: 0, y: 0);
        await db.saveActive(
          const ActiveSurvey(
            surveyId: 's1',
            userId: 'u1',
            buildingId: 'b1',
            buildingName: 'Main',
            floorId: 'f0',
            originLat: 0,
            originLng: 0,
            x: 0,
            y: 0,
            steps: 0,
            checkpointSteps: 0,
            startedMs: 1,
            readings: 1,
            checkpoints: 0,
          ),
        );
        expect(await c.end(), isTrue);
        expect(c.phase, SurveyPhase.done);
        expect(await db.heldCount('s1'), 0);
        expect(await db.activeFor('u1'), isNull);
        final seq = [for (final r in calls) '${r.method} ${r.url.path}'];
        expect(seq, [
          'POST /api/surveys/s1/readings',
          'PATCH /api/surveys/s1',
          'POST /api/surveys/s1/process',
        ]);
      },
    );

    test('if the upload fails the survey stays resumable', () async {
      c.phase = SurveyPhase.active;
      await db.add(SyncKind.readings, 's1', reading('a', 0, 0), x: 0, y: 0);
      await db.saveActive(
        const ActiveSurvey(
          surveyId: 's1',
          userId: 'u1',
          buildingId: 'b1',
          buildingName: 'Main',
          floorId: 'f0',
          originLat: 0,
          originLng: 0,
          x: 0,
          y: 0,
          steps: 0,
          checkpointSteps: 0,
          startedMs: 1,
          readings: 1,
          checkpoints: 0,
        ),
      );
      routes['POST /api/surveys/s1/readings'] = (_) =>
          jsonResponse({'detail': 'Nope'}, 422);
      expect(await c.end(), isFalse);
      expect(c.phase, SurveyPhase.endFailed);
      expect(await db.activeFor('u1'), isNotNull);
    });
  });

  group('live preview heatmap (FR-11a)', () {
    Map<String, dynamic> previewResponse(List<dynamic> values) => {
      'computed_at': '2026-11-16T10:00:00Z',
      'grids': [
        {
          'floor_id': 'f0',
          'bssid': null,
          'cell_size_m': 2.0,
          'origin_lat': 0.0,
          'origin_lng': 0.0,
          'cols': 2,
          'rows': 1,
          'values': values,
        },
      ],
    };

    test('asks the API for the current floor and keeps the grid', () async {
      c.phase = SurveyPhase.active;
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse(previewResponse([-55, -75]));
      await c.previewTick();
      expect(calls.single.url.queryParameters, {
        'preview': 'true',
        'floor_id': 'f0',
      });
      expect(c.preview!.floorId, 'f0');
      expect(c.preview!.filledCells, 2);
      expect(c.previewStale, isFalse);
      expect(c.previewAt, isNotNull);
    });

    test('is not asked again before a minute has passed', () async {
      c.phase = SurveyPhase.active;
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse(previewResponse([-55, -75]));
      await c.previewTick();
      await c.previewTick();
      expect(calls, hasLength(1));
    });

    test('a failure is quiet: the last grid stays and is marked old', () async {
      c.phase = SurveyPhase.active;
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse(previewResponse([-55, -75]));
      await c.previewTick();
      // A manual floor change asks again at once, and the server is down.
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse({'detail': 'boom'}, 500);
      c.setFloor(f1);
      c.setFloor(f0);
      await c.previewTick();
      expect(c.preview, isNotNull);
      expect(c.previewStale, isTrue);
      expect(c.error, isNull);
      expect(c.message, isNull);
    });

    test('an empty answer does not wipe the grid', () async {
      c.phase = SurveyPhase.active;
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse(previewResponse([-55, -75]));
      await c.previewTick();
      c.setFloor(f0);
      routes['POST /api/surveys/s1/process'] = (_) =>
          jsonResponse(previewResponse([null, null]));
      await c.previewTick();
      expect(c.preview!.filledCells, 2);
    });

    test('does nothing before the survey starts', () async {
      c.phase = SurveyPhase.ready;
      await c.previewTick();
      expect(calls, isEmpty);
    });
  });
}
