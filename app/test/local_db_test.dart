import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/geo.dart';
import 'package:signalscape_mobile/core/sync_engine.dart';
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

Map<String, dynamic> reading(String id, double x, double y) {
  final g = toGeo(x, y, 0, 0);
  return {'client_id': id, 'lat': g.lat, 'lng': g.lng, 'rssi_dbm': -60};
}

void main() {
  setUpAll(useFfiSqlite);

  late LocalDb db;
  setUp(() async => db = await memoryDb());
  tearDown(() => db.close());

  Future<List<Map<String, dynamic>>> sendable() async =>
      (await db.nextBatch(100))?.items ?? [];

  test('a reading with a position is held back from upload', () async {
    await db.add(SyncKind.readings, 's', reading('a', 0, 0), x: 0, y: 0);
    await db.add(SyncKind.readings, 's', reading('b', 1, 0));
    expect(await db.heldCount('s'), 1);
    expect([for (final r in await sendable()) r['client_id']], ['b']);
    expect(await db.pendingCount(), 1);
  });

  test('checkpoints are never held', () async {
    await db.add(SyncKind.checkpoints, 's', {'client_id': 'c'});
    expect((await db.nextBatch(10))!.kind, SyncKind.checkpoints);
    expect(await db.pendingCount(), 1);
  });

  test('applyCorrection spreads the error and releases the readings', () async {
    // Walked east 0, 5, 10 steps; the checkpoint says we are 2 m further north.
    await db.add(
      SyncKind.readings,
      's',
      reading('a', 0, 0),
      x: 0,
      y: 0,
      progress: 0,
    );
    await db.add(
      SyncKind.readings,
      's',
      reading('b', 5, 0),
      x: 5,
      y: 0,
      progress: 5,
    );
    await db.add(
      SyncKind.readings,
      's',
      reading('c', 10, 0),
      x: 10,
      y: 0,
      progress: 10,
    );
    final n = await db.applyCorrection(
      's',
      errX: 0,
      errY: 2,
      startProgress: 0,
      endProgress: 10,
      originLat: 0,
      originLng: 0,
    );
    expect(n, 3);
    expect(await db.heldCount('s'), 0);
    final out = {for (final r in await sendable()) r['client_id']: r};
    double northOf(String id) =>
        toLocal(out[id]!['lat'] as double, out[id]!['lng'] as double, 0, 0).y;
    expect(northOf('a'), closeTo(0, 1e-3));
    expect(northOf('b'), closeTo(1, 1e-3));
    expect(northOf('c'), closeTo(2, 1e-3));
    // The rest of the body is untouched.
    expect(out['a']!['rssi_dbm'], -60);
  });

  test('applyCorrection only touches this survey', () async {
    await db.add(SyncKind.readings, 's', reading('a', 0, 0), x: 0, y: 0);
    await db.add(SyncKind.readings, 'other', reading('z', 0, 0), x: 0, y: 0);
    await db.applyCorrection(
      's',
      errX: 1,
      errY: 1,
      startProgress: 0,
      endProgress: 1,
      originLat: 0,
      originLng: 0,
    );
    expect(await db.heldCount('s'), 0);
    expect(await db.heldCount('other'), 1);
  });

  test('releaseHeld lets readings go as they are', () async {
    await db.add(SyncKind.readings, 's', reading('a', 3, 4), x: 3, y: 4);
    final before = jsonEncode(reading('a', 3, 4));
    expect(await db.releaseHeld('s'), 1);
    final sent = await sendable();
    expect(jsonEncode(sent.single), before);
  });

  test('releaseHeld with olderThan keeps recent readings held', () async {
    await db.add(SyncKind.readings, 's', reading('a', 0, 0), x: 0, y: 0);
    expect(await db.releaseHeld('s', olderThan: const Duration(minutes: 4)), 0);
    expect(await db.heldCount('s'), 1);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(await db.releaseHeld('s', olderThan: Duration.zero), 1);
  });

  test('markSynced still works for released readings', () async {
    await db.add(SyncKind.readings, 's', reading('a', 0, 0), x: 0, y: 0);
    await db.releaseHeld('s');
    final batch = (await db.nextBatch(10))!;
    await db.markSynced(batch);
    expect(await db.nextBatch(10), isNull);
    expect(await db.readingCount('s'), 1);
  });

  test(
    'the unfinished survey is saved, replaced, found by user and cleared',
    () async {
      ActiveSurvey make(int steps, {String user = 'u1'}) => ActiveSurvey(
        surveyId: 's1',
        userId: user,
        buildingId: 'b1',
        buildingName: 'Main',
        floorId: 'f1',
        originLat: 14.5,
        originLng: 121.0,
        x: 1.5,
        y: -2.5,
        steps: steps,
        checkpointSteps: 3,
        startedMs: 1000,
        readings: 12,
        checkpoints: 2,
      );
      expect(await db.activeFor('u1'), isNull);
      await db.saveActive(make(10));
      await db.saveActive(make(20));
      final a = (await db.activeFor('u1'))!;
      expect(a.steps, 20);
      expect(a.surveyId, 's1');
      expect(a.buildingName, 'Main');
      expect(a.x, 1.5);
      expect(a.y, -2.5);
      expect(a.checkpointSteps, 3);
      expect(a.readings, 12);
      expect(await db.activeFor('someone-else'), isNull);
      await db.clearActive();
      expect(await db.activeFor('u1'), isNull);
    },
  );

  test('a version 1 database is upgraded and keeps its rows', () async {
    final dir = Directory('.dart_tool/db_test')..createSync(recursive: true);
    final path = File('${dir.path}/v1.db').absolute.path;
    if (File(path).existsSync()) File(path).deleteSync();
    final v1 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (d, _) async {
          for (final t in const ['readings', 'checkpoints']) {
            await d.execute(
              'CREATE TABLE $t (client_id TEXT PRIMARY KEY, survey_id TEXT '
              'NOT NULL, body TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT '
              '0, created_ms INTEGER NOT NULL)',
            );
          }
          await d.insert('readings', {
            'client_id': 'old',
            'survey_id': 's',
            'body': jsonEncode({'client_id': 'old'}),
            'synced': 0,
            'created_ms': 1,
          });
        },
      ),
    );
    await v1.close();
    final upgraded = await LocalDb.openIn(path);
    // The old reading is not held and can still go up.
    expect((await upgraded.nextBatch(10))!.ids, ['old']);
    expect(await upgraded.heldCount('s'), 0);
    await upgraded.add(SyncKind.readings, 's', reading('n', 0, 0), x: 0, y: 0);
    expect(await upgraded.heldCount('s'), 1);
    expect(await upgraded.activeFor('u'), isNull);
    await upgraded.close();
    File(path).deleteSync();
  });
}
