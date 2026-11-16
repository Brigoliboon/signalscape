import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/survey_models.dart';
import 'package:signalscape_mobile/screens/buildings_screen.dart';
import 'package:signalscape_mobile/screens/map_screen.dart';
import 'package:signalscape_mobile/screens/survey_history_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

Map<String, dynamic> surveyJson(
  String id, {
  String building = 'b1',
  String surveyor = 'u1',
  String status = 'processed',
  String started = '2026-11-16T06:05:00Z',
  String? ended = '2026-11-16T06:50:00Z',
  String? notes,
}) => {
  'id': id,
  'building_id': building,
  'surveyor_id': surveyor,
  'status': status,
  'started_at': started,
  'ended_at': ended,
  'device_model': 'Pixel 7',
  'has_barometer': true,
  'origin_lat': 14.5,
  'origin_lng': 121.0,
  'origin_accuracy_m': 5.0,
  'step_length_m': 0.7,
  'notes': notes,
  'processed_at': status == 'processed' ? '2026-11-16T06:55:00Z' : null,
  'created_at': started,
  'updated_at': started,
};

Map<String, dynamic> page(
  List<Map<String, dynamic>> items,
  int total,
  int pageNo,
) => {'items': items, 'total': total, 'page': pageNo, 'page_size': 2};

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  late List<http.Request> calls;

  /// A history whose API has [all] surveys and deletes them on request.
  Future<void> mount(
    WidgetTester tester, {
    String role = 'surveyor',
    List<Map<String, dynamic>>? all,
    Future<http.Response> Function(http.Request)? onDelete,
    bool listFails = false,
    Future<LocalDb> Function()? openDb,
  }) async {
    tall(tester);
    calls = [];
    final surveys =
        all ??
        [
          surveyJson('s1'),
          surveyJson(
            's2',
            building: 'b2',
            status: 'completed',
            ended: '2026-11-15T07:00:00Z',
            started: '2026-11-15T06:00:00Z',
            notes: 'Second floor wing',
          ),
        ];
    final session = signedIn((req) async {
      calls.add(req);
      final path = req.url.path;
      if (req.method == 'DELETE') {
        return onDelete != null ? onDelete(req) : http.Response('', 204);
      }
      if (path.endsWith('/api/buildings')) {
        return jsonResponse({
          'items': [
            buildingJson('b1', 'Main Tower'),
            buildingJson('b2', 'Annex'),
          ],
          'total': 2,
          'page': 1,
          'page_size': 100,
        });
      }
      if (path.endsWith('/api/surveys')) {
        if (listFails) return jsonResponse({'detail': 'Boom'}, 500);
        final q = req.url.queryParameters;
        var items = surveys;
        if (q['status'] != null) {
          items = [
            for (final s in items)
              if (s['status'] == q['status']) s,
          ];
        }
        if (q['building_id'] != null) {
          items = [
            for (final s in items)
              if (s['building_id'] == q['building_id']) s,
          ];
        }
        final pageNo = int.parse(q['page'] ?? '1');
        final size = int.parse(q['page_size'] ?? '20');
        final from = (pageNo - 1) * size;
        final slice = items.skip(from).take(size).toList();
        return jsonResponse(page(slice, items.length, pageNo));
      }
      return jsonResponse({'detail': 'Not found'}, 404);
    }, role: role);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SurveyHistoryScreen(
          session: session,
          pageSize: 2,
          openDb: openDb ?? () async => throw StateError('no db'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('lists surveys newest first with building and status', (
    tester,
  ) async {
    await mount(tester);
    final list = calls.firstWhere((c) => c.url.path.endsWith('/api/surveys'));
    expect(list.url.queryParameters['sort'], '-started_at');
    expect(list.url.queryParameters['page_size'], '2');
    expect(find.text('2 surveys'), findsOneWidget);
    expect(find.text('Main Tower'), findsWidgets);
    expect(find.text('Annex'), findsWidgets);
    expect(find.textContaining('Processed'), findsWidgets);
    expect(find.textContaining('Not processed'), findsWidgets);
  });

  testWidgets('the status filter asks the API for that status', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('filter-completed')));
    await tester.pump();
    await tester.pump();
    expect(calls.last.url.queryParameters['status'], 'completed');
    expect(find.byKey(const ValueKey('survey-s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('survey-s1')), findsNothing);
    expect(find.text('1 survey'), findsOneWidget);
  });

  testWidgets('the building filter asks the API for that building', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('building-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annex').last);
    await tester.pumpAndSettle();
    expect(calls.last.url.queryParameters['building_id'], 'b2');
    expect(find.byKey(const ValueKey('survey-s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('survey-s1')), findsNothing);
  });

  testWidgets('pages on demand', (tester) async {
    await mount(tester, all: [for (var i = 1; i <= 3; i++) surveyJson('s$i')]);
    expect(find.byKey(const ValueKey('survey-s3')), findsNothing);
    await tester.tap(find.text('Load more (2 of 3)'));
    await tester.pump();
    await tester.pump();
    expect(calls.last.url.queryParameters['page'], '2');
    expect(find.byKey(const ValueKey('survey-s3')), findsOneWidget);
    expect(find.textContaining('Load more'), findsNothing);
  });

  testWidgets('says so when there are no surveys', (tester) async {
    await mount(tester, all: []);
    expect(find.textContaining('No surveys yet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('filter-processed')));
    await tester.pump();
    await tester.pump();
    expect(find.text('No surveys match this filter.'), findsOneWidget);
  });

  testWidgets('a failed load shows the reason and can be retried', (
    tester,
  ) async {
    await mount(tester, listFails: true);
    expect(find.text('Could not load surveys: Boom'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('offline is explained', (tester) async {
    tall(tester);
    final session = signedIn((req) async => throw http.ClientException('down'));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SurveyHistoryScreen(session: session),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining("You're offline"), findsOneWidget);
  });

  testWidgets('tapping a survey shows its details', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('survey-s2')));
    await tester.pumpAndSettle();
    expect(find.text('Pixel 7'), findsOneWidget);
    expect(find.text('Second floor wing'), findsOneWidget);
    expect(find.text('1 h 00 min'), findsOneWidget);
    expect(find.textContaining('has not been processed yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-map')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-3d')), findsOneWidget);
  });

  testWidgets('a survey opens on the 2D map', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('survey-s1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-map')));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MapScreen), findsOneWidget);
    expect(
      calls.any((c) => c.url.path.endsWith('/api/surveys/s1/summary')),
      isTrue,
    );
  });

  group('delete', () {
    testWidgets('asks first, then deletes and removes the row', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('survey-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-survey')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this survey?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(calls.where((c) => c.method == 'DELETE'), isEmpty);
      await tester.tap(find.text('Delete survey').last);
      await tester.pumpAndSettle();
      final del = calls.singleWhere((c) => c.method == 'DELETE');
      expect(del.url.path, '/api/surveys/s1');
      expect(find.byKey(const ValueKey('survey-s1')), findsNothing);
      expect(find.text('1 survey'), findsOneWidget);
      expect(find.text('Survey deleted.'), findsOneWidget);
    });

    testWidgets('Cancel deletes nothing', (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('survey-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-survey')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'DELETE'), isEmpty);
      expect(find.byKey(const ValueKey('survey-s1')), findsOneWidget);
    });

    testWidgets('a refusal is shown and the row stays', (tester) async {
      await mount(
        tester,
        onDelete: (_) async => jsonResponse({'detail': 'Not found'}, 404),
      );
      await tester.tap(find.byKey(const ValueKey('survey-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-survey')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete survey').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Could not delete the survey: Not found'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('survey-s1')), findsOneWidget);
    });

    testWidgets('a Viewer cannot delete', (tester) async {
      await mount(tester, role: 'viewer');
      await tester.tap(find.byKey(const ValueKey('survey-s1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-map')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-survey')), findsNothing);
    });

    testWidgets("an Admin can delete someone else's survey", (tester) async {
      await mount(
        tester,
        role: 'admin',
        all: [surveyJson('s9', surveyor: 'someone-else')],
      );
      await tester.tap(find.byKey(const ValueKey('survey-s9')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-survey')), findsOneWidget);
    });

    testWidgets("a Surveyor cannot delete someone else's survey", (
      tester,
    ) async {
      await mount(tester, all: [surveyJson('s9', surveyor: 'someone-else')]);
      await tester.tap(find.byKey(const ValueKey('survey-s9')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('delete-survey')), findsNothing);
    });

    testWidgets('forgets the same survey if the phone held it unfinished', (
      tester,
    ) async {
      useFfiSqlite();
      final db = (await tester.runAsync(() async {
        final d = await memoryDb();
        await d.saveActive(
          const ActiveSurvey(
            surveyId: 's1',
            userId: 'u1',
            buildingId: 'b1',
            buildingName: 'Main Tower',
            floorId: 'f0',
            originLat: 14.5,
            originLng: 121.0,
            x: 0,
            y: 0,
            steps: 0,
            checkpointSteps: 0,
            startedMs: 1,
            readings: 5,
            checkpoints: 0,
          ),
        );
        return d;
      }))!;
      addTearDown(() => db.close());
      await mount(tester, openDb: () async => db);
      await tester.tap(find.byKey(const ValueKey('survey-s1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-survey')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete survey').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final left = await tester.runAsync(() => db.activeFor('u1'));
      expect(left, isNull);
    });
  });

  testWidgets('the home screen opens the history', (tester) async {
    tall(tester);
    final session = signedIn((req) async {
      if (req.url.path.endsWith('/api/buildings')) {
        return jsonResponse({
          'items': <Object>[],
          'total': 0,
          'page': 1,
          'page_size': 20,
        });
      }
      return jsonResponse(page([], 0, 1));
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: BuildingsScreen(session: session, checkUnfinished: false),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open-history')));
    await tester.pumpAndSettle();
    expect(find.text('Survey history'), findsWidgets);
    expect(find.byType(SurveyHistoryScreen), findsOneWidget);
  });

  test('formatting helpers', () {
    final s = SurveyInfo.fromJson(surveyJson('x'));
    expect(surveyDuration(s), '45 min');
    expect(
      surveyDuration(SurveyInfo.fromJson(surveyJson('y', ended: null))),
      isNull,
    );
    expect(
      surveyDuration(
        SurveyInfo.fromJson(surveyJson('z', ended: '2026-11-16T06:05:20Z')),
      ),
      'under a minute',
    );
    expect(formatSurveyDate(DateTime(2026, 11, 3, 9, 5)), '3 Nov 2026, 09:05');
    expect(s.statusLabel, 'Processed');
    expect(canDeleteSurveys('viewer'), isFalse);
    expect(canDeleteSurveys('surveyor'), isTrue);
  });
}
