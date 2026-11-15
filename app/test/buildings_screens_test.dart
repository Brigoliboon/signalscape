import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/plan_image.dart';
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/models.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/screens/building_detail_screen.dart';
import 'package:signalscape_mobile/screens/building_form_screen.dart';
import 'package:signalscape_mobile/screens/buildings_screen.dart';
import 'package:signalscape_mobile/screens/floor_form_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A small valid PNG, so Image.memory has something it can decode.
final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

List<Map<String, dynamic>> buildings(int from, int to) => [
  for (var i = from; i <= to; i++)
    buildingJson('b$i', 'Building $i', address: '$i Road'),
];

Map<String, dynamic> pageJson(
  List<Map<String, dynamic>> items,
  int total,
  int page,
) => {'items': items, 'total': total, 'page': page, 'page_size': 2};

Future<void> mount(WidgetTester tester, Widget home) async {
  tall(tester);
  await tester.pumpWidget(MaterialApp(theme: buildTheme(), home: home));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('buildings list', () {
    late List<http.Request> calls;

    Session sessionWith(String role, {int total = 3}) {
      calls = [];
      return signedIn((req) async {
        calls.add(req);
        final page = int.parse(req.url.queryParameters['page'] ?? '1');
        final q = req.url.queryParameters['q'];
        if (q == 'nomatch') return jsonResponse(pageJson([], 0, 1));
        return jsonResponse(
          page == 1
              ? pageJson(buildings(1, 2), total, 1)
              : pageJson(buildings(3, 3), total, 2),
        );
      }, role: role);
    }

    testWidgets('loads the first page and pages on demand', (tester) async {
      await mount(
        tester,
        BuildingsScreen(
          session: sessionWith('surveyor'),
          pageSize: 2,
          checkUnfinished: false,
        ),
      );
      expect(find.text('Building 1'), findsOneWidget);
      expect(find.text('Building 2'), findsOneWidget);
      expect(find.text('3 buildings'), findsOneWidget);
      expect(calls.single.url.queryParameters, {
        'page': '1',
        'page_size': '2',
        'sort': 'name',
      });
      expect(find.text('Load more (2 of 3)'), findsOneWidget);
      await tester.tap(find.text('Load more (2 of 3)'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Building 3'), findsOneWidget);
      expect(calls.last.url.queryParameters['page'], '2');
      expect(find.textContaining('Load more'), findsNothing);
    });

    testWidgets('search waits a moment, then asks the API', (tester) async {
      await mount(
        tester,
        BuildingsScreen(
          session: sessionWith('surveyor'),
          pageSize: 2,
          checkUnfinished: false,
        ),
      );
      await tester.enterText(find.byType(TextField), 'nomatch');
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, hasLength(1)); // still debouncing
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(calls.last.url.queryParameters['q'], 'nomatch');
      expect(calls.last.url.queryParameters['page'], '1');
      expect(find.text('No building matches your search.'), findsOneWidget);
    });

    testWidgets('sort changes go to the API', (tester) async {
      await mount(
        tester,
        BuildingsScreen(
          session: sessionWith('surveyor'),
          pageSize: 2,
          checkUnfinished: false,
        ),
      );
      await tester.tap(find.text('Name A–Z'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Newest first').last);
      await tester.pumpAndSettle();
      expect(calls.last.url.queryParameters['sort'], '-created_at');
    });

    testWidgets('Surveyors and Admins can add a building', (tester) async {
      for (final role in ['surveyor', 'admin']) {
        await mount(
          tester,
          BuildingsScreen(
            session: sessionWith(role),
            pageSize: 2,
            checkUnfinished: false,
          ),
        );
        expect(find.text('Add building'), findsOneWidget, reason: role);
      }
    });

    testWidgets('Viewers cannot add, and are told what they will see', (
      tester,
    ) async {
      final session = signedIn((req) async {
        return jsonResponse(pageJson([], 0, 1));
      }, role: 'viewer');
      await mount(
        tester,
        BuildingsScreen(session: session, pageSize: 2, checkUnfinished: false),
      );
      expect(find.text('Add building'), findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.textContaining('Viewers see surveys'), findsOneWidget);
    });

    testWidgets('an empty list invites a Surveyor to add the first building', (
      tester,
    ) async {
      final session = signedIn((_) async => jsonResponse(pageJson([], 0, 1)));
      await mount(
        tester,
        BuildingsScreen(session: session, pageSize: 2, checkUnfinished: false),
      );
      expect(find.textContaining('Add the first one'), findsOneWidget);
    });

    testWidgets('a failed load shows the error and can retry', (tester) async {
      var fail = true;
      final session = signedIn((_) async {
        return fail
            ? jsonResponse({'detail': 'Server down'}, 500)
            : jsonResponse(pageJson(buildings(1, 1), 1, 1));
      });
      await mount(
        tester,
        BuildingsScreen(session: session, pageSize: 2, checkUnfinished: false),
      );
      expect(find.text('Server down'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Server down'), findsNothing);
      expect(find.text('Building 1'), findsOneWidget);
    });
  });

  group('building details', () {
    Session session(String role, {List<Map<String, dynamic>>? floors}) =>
        signedIn((req) async {
          if (req.url.path == '/api/buildings/b1') {
            return jsonResponse(
              buildingJson(
                'b1',
                'Main',
                address: '1 Road',
                floors:
                    floors ??
                    [
                      floorJson('f0', 0, 'Ground', height: 4.0),
                      floorJson('f1', 1, 'First', height: 3.2),
                    ],
              ),
            );
          }
          return jsonResponse({});
        }, role: role);

    Building b() => const Building(id: 'b1', name: 'Main');

    testWidgets('shows the floors with level, height and plan state', (
      tester,
    ) async {
      await mount(
        tester,
        BuildingDetailScreen(session: session('surveyor'), building: b()),
      );
      expect(find.text('1 Road'), findsOneWidget);
      expect(find.text('FLOORS (2)'), findsOneWidget);
      expect(
        find.textContaining('Level 0 · 4.0 m high · no plan'),
        findsOneWidget,
      );
      expect(find.textContaining('Level 1 · 3.2 m high'), findsOneWidget);
    });

    testWidgets('a Surveyor can edit, add floors and start a survey', (
      tester,
    ) async {
      await mount(
        tester,
        BuildingDetailScreen(session: session('surveyor'), building: b()),
      );
      expect(find.byTooltip('Edit building'), findsOneWidget);
      expect(find.text('Add floor'), findsOneWidget);
      expect(find.byTooltip('Edit Ground'), findsOneWidget);
      expect(find.text('Start a survey'), findsOneWidget);
    });

    testWidgets('a Viewer sees the building but cannot change anything', (
      tester,
    ) async {
      await mount(
        tester,
        BuildingDetailScreen(session: session('viewer'), building: b()),
      );
      expect(find.text('FLOORS (2)'), findsOneWidget);
      expect(find.byTooltip('Edit building'), findsNothing);
      expect(find.text('Add floor'), findsNothing);
      expect(find.byTooltip('Edit Ground'), findsNothing);
      expect(find.text('Start a survey'), findsNothing);
    });

    testWidgets('a building with no floors asks for the first one', (
      tester,
    ) async {
      await mount(
        tester,
        BuildingDetailScreen(
          session: session('surveyor', floors: []),
          building: b(),
        ),
      );
      expect(find.textContaining('Add the first one'), findsOneWidget);
      expect(find.text('Start a survey'), findsNothing);
    });
  });

  group('building form', () {
    testWidgets('adding needs a name and sends what was typed', (tester) async {
      Map<String, dynamic>? body;
      final session = signedIn((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return jsonResponse(buildingJson('b9', 'Annex'), 201);
      });
      Building? result;
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  result = await Navigator.of(context).push<Building>(
                    MaterialPageRoute(
                      builder: (_) => BuildingFormScreen(session: session),
                    ),
                  ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add building'));
      await tester.pump();
      expect(find.text('Give the building a name.'), findsOneWidget);
      expect(body, isNull);
      await tester.enterText(find.byType(TextFormField).at(0), ' Annex ');
      await tester.enterText(find.byType(TextFormField).at(1), '2 Road');
      await tester.tap(find.widgetWithText(FilledButton, 'Add building'));
      await tester.pumpAndSettle();
      expect(body, {'name': 'Annex', 'address': '2 Road'});
      expect(result!.id, 'b9');
    });

    testWidgets(
      'editing starts from the current values and clears emptied ones',
      (tester) async {
        Map<String, dynamic>? body;
        final session = signedIn((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          expect(req.method, 'PATCH');
          return jsonResponse(buildingJson('b1', 'Main 2'));
        });
        await mount(
          tester,
          BuildingFormScreen(
            session: session,
            building: const Building(id: 'b1', name: 'Main', address: '1 Road'),
          ),
        );
        expect(find.text('Edit building'), findsOneWidget);
        expect(find.text('Main'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField).at(0), 'Main 2');
        await tester.enterText(find.byType(TextFormField).at(1), '');
        await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
        await tester.pump();
        await tester.pump();
        expect(body, {'name': 'Main 2', 'address': null, 'description': null});
      },
    );

    testWidgets('an API error stays on screen', (tester) async {
      final session = signedIn(
        (_) async => jsonResponse({'detail': 'Name taken'}, 409),
      );
      await mount(tester, BuildingFormScreen(session: session));
      await tester.enterText(find.byType(TextFormField).at(0), 'Main');
      await tester.tap(find.widgetWithText(FilledButton, 'Add building'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Name taken'), findsOneWidget);
    });
  });

  group('floor form', () {
    late List<http.Request> calls;

    Session session({int planStatus = 200}) {
      calls = [];
      return signedIn((req) async {
        calls.add(req);
        if (req.method == 'PUT') {
          return planStatus == 200
              ? jsonResponse(
                  floorJson('f9', 2, 'Floor 2', planUrl: '/api/floors/f9/plan'),
                )
              : jsonResponse({
                  'detail': 'Floor plan must be a PNG or JPEG image',
                }, 400);
        }
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return jsonResponse(
          floorJson(
            'f9',
            body['level'] as int,
            body['label'] as String,
            height: (body['height_m'] as num).toDouble(),
          ),
          201,
        );
      });
    }

    Future<Floor?> openForm(
      WidgetTester tester,
      Session s, {
      PlanPicker? picker,
      Floor? floor,
    }) async {
      Floor? result;
      var done = false;
      await mount(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<Floor>(
                  MaterialPageRoute(
                    builder: (_) => FloorFormScreen(
                      session: s,
                      buildingId: 'b1',
                      floor: floor,
                      existingLevels: const [0, 1],
                      pickPlan: picker ?? () async => null,
                    ),
                  ),
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      addTearDown(() => done);
      return result;
    }

    testWidgets('suggests the next level and the default height', (
      tester,
    ) async {
      await openForm(tester, session());
      expect(find.text('Add floor'), findsWidgets);
      expect(find.widgetWithText(TextFormField, 'Floor 2'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '3.0'), findsOneWidget);
    });

    testWidgets('checks the fields before saving', (tester) async {
      await openForm(tester, session());
      await tester.enterText(find.byType(TextFormField).at(1), 'x');
      await tester.enterText(find.byType(TextFormField).at(2), '0');
      await tester.enterText(find.byType(TextFormField).at(3), 'wide');
      await tester.tap(find.widgetWithText(FilledButton, 'Add floor'));
      await tester.pump();
      expect(
        find.textContaining('Level must be a whole number'),
        findsOneWidget,
      );
      expect(find.textContaining('Height must be above 0'), findsOneWidget);
      expect(find.textContaining('Enter a number in metres'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('saves the floor with its height', (tester) async {
      await openForm(tester, session());
      await tester.enterText(find.byType(TextFormField).at(0), 'Rooftop');
      await tester.enterText(find.byType(TextFormField).at(2), '3.4');
      await tester.tap(find.widgetWithText(FilledButton, 'Add floor'));
      await tester.pumpAndSettle();
      expect(calls.single.method, 'POST');
      expect(jsonDecode(calls.single.body), {
        'level': 2,
        'label': 'Rooftop',
        'height_m': 3.4,
      });
    });

    testWidgets('a chosen PNG is uploaded after the floor is saved', (
      tester,
    ) async {
      await openForm(
        tester,
        session(),
        picker: () async => PickedPlan(pngBytes),
      );
      await tester.tap(find.text('Choose floor plan'));
      await tester.pump();
      expect(find.text('Choose a different plan'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add floor'));
      await tester.pumpAndSettle();
      expect([for (final r in calls) r.method], ['POST', 'PUT']);
      expect(calls.last.url.path, '/api/floors/f9/plan');
      expect(
        calls.last.headers['content-type'],
        startsWith('multipart/form-data'),
      );
    });

    testWidgets('a GIF is refused before anything is uploaded', (tester) async {
      await openForm(
        tester,
        session(),
        picker: () async => PickedPlan(
          Uint8List.fromList([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
        ),
      );
      await tester.tap(find.text('Choose floor plan'));
      await tester.pump();
      expect(find.text(planCheckMessage(PlanCheck.notImage)), findsOneWidget);
      expect(find.text('Choose a different plan'), findsNothing);
    });

    testWidgets('a plan over 5 MB is refused', (tester) async {
      await openForm(
        tester,
        session(),
        picker: () async => PickedPlan(
          Uint8List.fromList([...pngBytes, ...List.filled(maxPlanBytes, 0)]),
        ),
      );
      await tester.tap(find.text('Choose floor plan'));
      await tester.pump();
      expect(find.text(planCheckMessage(PlanCheck.tooLarge)), findsOneWidget);
    });

    testWidgets(
      'if the plan upload fails the floor is kept and the error shown',
      (tester) async {
        await openForm(
          tester,
          session(planStatus: 400),
          picker: () async => PickedPlan(pngBytes),
        );
        await tester.tap(find.text('Choose floor plan'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Add floor'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('The floor was saved, but the plan'),
          findsOneWidget,
        );
        // Saving again does not create the floor twice.
        await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
        await tester.pumpAndSettle();
        expect([for (final r in calls) r.method], ['POST', 'PUT', 'PUT']);
      },
    );
  });

  group('unfinished survey', () {
    setUpAll(useFfiSqlite);

    const survey = ActiveSurvey(
      surveyId: 's1',
      userId: 'u1',
      buildingId: 'b1',
      buildingName: 'Main Tower',
      floorId: 'f0',
      originLat: 14.5,
      originLng: 121.0,
      x: 1,
      y: 2,
      steps: 30,
      checkpointSteps: 10,
      startedMs: 1,
      readings: 42,
      checkpoints: 3,
    );

    Future<LocalDb> dbWithSurvey(WidgetTester tester) async {
      final db = (await tester.runAsync(() async {
        final d = await memoryDb();
        await d.saveActive(survey);
        return d;
      }))!;
      addTearDown(() => db.close());
      return db;
    }

    Future<void> settleDb(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('the next launch offers to resume or end it', (tester) async {
      final db = await dbWithSurvey(tester);
      final session = signedIn((_) async => jsonResponse(pageJson([], 0, 1)));
      await mount(
        tester,
        BuildingsScreen(session: session, openDb: () async => db),
      );
      await settleDb(tester);
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
      expect(inDialog(find.text('Unfinished survey')), findsOneWidget);
      expect(inDialog(find.textContaining('Main Tower')), findsOneWidget);
      expect(
        inDialog(find.textContaining('42 readings, 3 checkpoints')),
        findsOneWidget,
      );
      expect(inDialog(find.text('Resume')), findsOneWidget);
      expect(inDialog(find.text('End survey')), findsOneWidget);
      expect(inDialog(find.text('Later')), findsOneWidget);
    });

    testWidgets('Later keeps a card on the home screen', (tester) async {
      final db = await dbWithSurvey(tester);
      final session = signedIn((_) async => jsonResponse(pageJson([], 0, 1)));
      await mount(
        tester,
        BuildingsScreen(session: session, openDb: () async => db),
      );
      await settleDb(tester);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.text('Unfinished survey'), findsOneWidget); // the card
      expect(find.text('Main Tower · 42 readings'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
    });

    testWidgets('End survey uploads, completes and processes it', (
      tester,
    ) async {
      final db = await dbWithSurvey(tester);
      final calls = <String>[];
      final session = signedIn((req) async {
        calls.add('${req.method} ${req.url.path}');
        return req.url.path == '/api/buildings'
            ? jsonResponse(pageJson([], 0, 1))
            : jsonResponse({});
      });
      await mount(
        tester,
        BuildingsScreen(session: session, openDb: () async => db),
      );
      await settleDb(tester);
      await tester.tap(find.widgetWithText(TextButton, 'End survey'));
      await tester.pump();
      await settleDb(tester);
      await settleDb(tester);
      expect(calls, [
        'GET /api/buildings',
        'PATCH /api/surveys/s1',
        'POST /api/surveys/s1/process',
      ]);
      expect(find.text('Survey finished and processed.'), findsOneWidget);
      final left = await tester.runAsync(() => db.activeFor('u1'));
      expect(left, isNull);
    });

    testWidgets('a survey that belongs to someone else is not offered', (
      tester,
    ) async {
      final db = await dbWithSurvey(tester);
      final session = signedIn((_) async => jsonResponse(pageJson([], 0, 1)));
      session.user = User.fromJson({...userJson(), 'id': 'someone-else'});
      await mount(
        tester,
        BuildingsScreen(session: session, openDb: () async => db),
      );
      await settleDb(tester);
      expect(find.text('Unfinished survey'), findsNothing);
    });
  });
}
