import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/models.dart';
import 'package:signalscape_mobile/core/sync_engine.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/screens/building_detail_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

void main() {
  late List<http.Request> calls;
  late List<Map<String, dynamic>> floors;
  late Session session;
  Future<http.Response> Function(http.Request) onDelete = (r) async =>
      http.Response('', 204);

  Future<void> mount(
    WidgetTester tester, {
    String role = 'surveyor',
    Future<LocalDb> Function()? openDb,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    calls = [];
    session = signedIn((req) async {
      calls.add(req);
      if (req.method == 'DELETE') {
        final res = await onDelete(req);
        if (res.statusCode == 204 && req.url.path.startsWith('/api/floors/')) {
          floors.removeWhere((f) => req.url.path.endsWith('/${f['id']}'));
        }
        return res;
      }
      if (req.url.path == '/api/buildings/b1') {
        return jsonResponse(buildingJson('b1', 'Main', floors: floors));
      }
      return jsonResponse({});
    }, role: role);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        navigatorKey: navKey,
        home: const Scaffold(body: Text('Home page')),
      ),
    );
    navKey.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => BuildingDetailScreen(
          session: session,
          building: const Building(id: 'b1', name: 'Main'),
          openDb: openDb ?? () async => throw StateError('no db'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  List<http.Request> deletes() =>
      calls.where((c) => c.method == 'DELETE').toList();

  setUp(() {
    floors = [floorJson('f0', 0, 'Ground'), floorJson('f1', 1, 'First')];
    onDelete = (r) async => http.Response('', 204);
  });

  group('delete a floor', () {
    testWidgets('asks first; Cancel deletes nothing', (tester) async {
      await mount(tester);
      await tester.tap(key('delete-floor-f1'));
      await tester.pumpAndSettle();
      expect(find.text('Delete First?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes(), isEmpty);
      expect(find.text('FLOORS (2)'), findsOneWidget);
    });

    testWidgets('confirming removes it and reloads the building', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(key('delete-floor-f1'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(deletes().single.url.path, '/api/floors/f1');
      expect(find.text('FLOORS (1)'), findsOneWidget);
      expect(key('delete-floor-f1'), findsNothing);
      expect(find.text('First was deleted.'), findsOneWidget);
    });

    testWidgets('deleting the last floor shows the empty state', (
      tester,
    ) async {
      floors = [floorJson('f0', 0, 'Ground')];
      await mount(tester);
      await tester.tap(key('delete-floor-f0'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text('FLOORS (0)'), findsOneWidget);
      expect(find.textContaining('No floors yet'), findsOneWidget);
      expect(find.text('Start a survey'), findsNothing);
    });

    testWidgets('a refusal is explained and the floor stays', (tester) async {
      onDelete = (r) async => jsonResponse({'detail': 'Not found'}, 404);
      await mount(tester);
      await tester.tap(key('delete-floor-f1'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text('Could not delete: Not found'), findsOneWidget);
      expect(find.text('FLOORS (2)'), findsOneWidget);
    });

    testWidgets('offline says nothing was deleted', (tester) async {
      onDelete = (r) async => throw http.ClientException('down');
      await mount(tester);
      await tester.tap(key('delete-floor-f1'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text("You're offline. Nothing was deleted."), findsOneWidget);
      expect(find.text('FLOORS (2)'), findsOneWidget);
    });
  });

  group('delete a building', () {
    testWidgets('asks first and says what goes; Cancel keeps it', (
      tester,
    ) async {
      await mount(tester);
      await tester.tap(key('delete-building'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Main?'), findsOneWidget);
      expect(find.textContaining('its 2 floors'), findsOneWidget);
      expect(find.textContaining('every survey done here'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(deletes(), isEmpty);
      expect(find.text('Home page'), findsNothing); // still on the details
    });

    testWidgets('confirming deletes it and goes back', (tester) async {
      await mount(tester);
      await tester.tap(key('delete-building'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(deletes().single.url.path, '/api/buildings/b1');
      expect(find.text('Home page'), findsOneWidget);
      expect(find.text('Main was deleted.'), findsOneWidget);
    });

    testWidgets('one floor reads "1 floor"', (tester) async {
      floors = [floorJson('f0', 0, 'Ground')];
      await mount(tester);
      await tester.tap(key('delete-building'));
      await tester.pumpAndSettle();
      expect(find.textContaining('its 1 floor with'), findsOneWidget);
    });

    testWidgets('a refusal keeps the building and says why', (tester) async {
      onDelete = (r) async => jsonResponse({'detail': 'Forbidden'}, 403);
      await mount(tester);
      await tester.tap(key('delete-building'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text('Could not delete: Forbidden'), findsOneWidget);
      expect(find.text('Home page'), findsNothing);
      expect(
        tester.widget<IconButton>(key('delete-building')).onPressed,
        isNotNull,
      );
    });

    testWidgets('offline keeps the building and says so', (tester) async {
      onDelete = (r) async => throw http.ClientException('down');
      await mount(tester);
      await tester.tap(key('delete-building'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-delete'));
      await tester.pumpAndSettle();
      expect(find.text("You're offline. Nothing was deleted."), findsOneWidget);
      expect(deletes(), hasLength(1));
      expect(find.text('Home page'), findsNothing);
    });

    group('an unfinished survey on this phone', () {
      ActiveSurvey survey(String buildingId) => ActiveSurvey(
        surveyId: 's1',
        userId: 'u1',
        buildingId: buildingId,
        buildingName: 'Main',
        floorId: 'f0',
        originLat: 14.5,
        originLng: 121.0,
        x: 0,
        y: 0,
        steps: 0,
        checkpointSteps: 0,
        startedMs: 1,
        readings: 1,
        checkpoints: 0,
      );

      Future<LocalDb> dbWith(WidgetTester tester, String buildingId) async {
        useFfiSqlite();
        final db = (await tester.runAsync(() async {
          final d = await memoryDb();
          await d.saveActive(survey(buildingId));
          await d.add(SyncKind.readings, 's1', {'client_id': 'r1'});
          return d;
        }))!;
        addTearDown(() => db.close());
        return db;
      }

      Future<void> deleteMain(WidgetTester tester) async {
        await tester.tap(key('delete-building'));
        await tester.pumpAndSettle();
        await tester.tap(key('confirm-delete'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('is forgotten with its readings', (tester) async {
        final db = await dbWith(tester, 'b1');
        await mount(tester, openDb: () async => db);
        await deleteMain(tester);
        expect(find.text('Home page'), findsOneWidget);
        expect(await tester.runAsync(() => db.activeFor('u1')), isNull);
        expect(await tester.runAsync(() => db.pendingCount()), 0);
      });

      testWidgets('of another building is left alone', (tester) async {
        final db = await dbWith(tester, 'other');
        await mount(tester, openDb: () async => db);
        await deleteMain(tester);
        expect(find.text('Home page'), findsOneWidget);
        expect(await tester.runAsync(() => db.activeFor('u1')), isNotNull);
        expect(await tester.runAsync(() => db.pendingCount()), 1);
      });
    });
  });

  testWidgets('a Viewer sees no delete buttons', (tester) async {
    await mount(tester, role: 'viewer');
    expect(key('delete-building'), findsNothing);
    expect(key('delete-floor-f0'), findsNothing);
  });
}
