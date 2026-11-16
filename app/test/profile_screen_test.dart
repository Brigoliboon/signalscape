import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/sync_engine.dart';
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/screens/buildings_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

void main() {
  late List<http.Request> calls;
  late Session session;

  Future<void> mount(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler, {
    String role = 'surveyor',
    Future<LocalDb> Function()? openDb,
  }) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    calls = [];
    session = signedIn((req) async {
      calls.add(req);
      return handler(req);
    }, role: role);
    // The profile is reached from the home screen, so mount that and tap in:
    // sign out and delete then have a real stack to pop.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: BuildingsScreen(
          session: session,
          checkUnfinished: false,
          openDb: openDb ?? () async => throw StateError('no db'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open-profile')));
    await tester.pumpAndSettle();
  }

  Future<http.Response> ok(http.Request req) async {
    if (req.url.path.endsWith('/buildings')) {
      return jsonResponse({
        'items': <Object>[],
        'total': 0,
        'page': 1,
        'page_size': 20,
      });
    }
    if (req.method == 'PATCH') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final u = userJson();
      if (body.containsKey('name')) u['name'] = body['name'];
      if (body.containsKey('good_threshold_dbm')) {
        u['good_threshold_dbm'] = body['good_threshold_dbm'];
      }
      if (body.containsKey('dead_threshold_dbm')) {
        u['dead_threshold_dbm'] = body['dead_threshold_dbm'];
      }
      return jsonResponse(u);
    }
    if (req.method == 'DELETE') return http.Response('', 204);
    return jsonResponse({'detail': 'Not found'}, 404);
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  List<http.Request> patches() =>
      calls.where((c) => c.method == 'PATCH').toList();

  testWidgets('opens from the home screen and shows the account', (
    tester,
  ) async {
    await mount(tester, ok);
    expect(find.text('Profile and settings'), findsOneWidget);
    expect(find.text('a@b.co · surveyor'), findsOneWidget);
    expect(find.text('Privacy consent given.'), findsOneWidget);
    expect(find.text('Good: -67 dBm or stronger'), findsOneWidget);
    expect(find.text('Dead: weaker than -80 dBm'), findsOneWidget);
    // Nothing changed yet: nothing to save.
    expect(tester.widget<FilledButton>(key('save-profile')).onPressed, isNull);
  });

  testWidgets('saves a new name', (tester) async {
    await mount(tester, ok);
    await tester.enterText(key('profile-name'), '  Boon J  ');
    await tester.pump();
    await tester.tap(key('save-profile'));
    await tester.pumpAndSettle();
    final body = jsonDecode(patches().single.body) as Map<String, dynamic>;
    expect(body, {'name': 'Boon J'});
    expect(session.user!.name, 'Boon J');
    expect(find.text('Saved.'), findsOneWidget);
  });

  testWidgets('an empty name is refused before calling the API', (
    tester,
  ) async {
    await mount(tester, ok);
    await tester.enterText(key('profile-name'), '   ');
    await tester.pump();
    await tester.tap(key('save-profile'));
    await tester.pump();
    expect(find.text('Enter your name.'), findsOneWidget);
    expect(patches(), isEmpty);
  });

  testWidgets('saves thresholds, both together', (tester) async {
    await mount(tester, ok);
    // Make "good" weaker, the way the slider reports a drag.
    tester.widget<Slider>(key('threshold-good')).onChanged!(-72);
    await tester.pump();
    await tester.tap(key('save-profile'));
    await tester.pumpAndSettle();
    final body = jsonDecode(patches().single.body) as Map<String, dynamic>;
    expect(body.keys.toSet(), {'good_threshold_dbm', 'dead_threshold_dbm'});
    expect(body['good_threshold_dbm'], -72);
    expect(body['dead_threshold_dbm'], -80);
    expect(session.user!.thresholds.goodDbm, body['good_threshold_dbm']);
  });

  testWidgets('dead must stay below good', (tester) async {
    await mount(tester, ok);
    // "Dead" stronger than "good".
    tester.widget<Slider>(key('threshold-dead')).onChanged!(-50);
    await tester.pump();
    expect(key('threshold-error'), findsOneWidget);
    expect(tester.widget<FilledButton>(key('save-profile')).onPressed, isNull);
    expect(patches(), isEmpty);
  });

  testWidgets('a refused save is explained', (tester) async {
    await mount(tester, (req) async {
      if (req.method == 'PATCH') {
        return jsonResponse({'detail': 'Nope'}, 422);
      }
      return ok(req);
    });
    await tester.enterText(key('profile-name'), 'Other');
    await tester.pump();
    await tester.tap(key('save-profile'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved: Nope'), findsOneWidget);
    expect(session.user!.name, 'A');
  });

  testWidgets('saving while offline is explained', (tester) async {
    await mount(tester, (req) async {
      if (req.method == 'PATCH') throw http.ClientException('down');
      return ok(req);
    });
    await tester.enterText(key('profile-name'), 'Other');
    await tester.pump();
    await tester.tap(key('save-profile'));
    await tester.pumpAndSettle();
    expect(find.textContaining("You're offline"), findsOneWidget);
  });

  group('password', () {
    Future<void> fill(
      WidgetTester tester, {
      String current = 'old-password',
      String next = 'new-password',
      String confirm = 'new-password',
    }) async {
      await tester.enterText(key('password-current'), current);
      await tester.enterText(key('password-new'), next);
      await tester.enterText(key('password-confirm'), confirm);
      await tester.ensureVisible(key('save-password'));
      await tester.tap(key('save-password'));
      await tester.pumpAndSettle();
    }

    testWidgets('checks the fields first', (tester) async {
      await mount(tester, ok);
      await fill(tester, current: '', next: 'short', confirm: 'other');
      expect(find.text('Enter your current password.'), findsOneWidget);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(patches(), isEmpty);
    });

    testWidgets('changes it and clears the fields', (tester) async {
      await mount(tester, ok);
      await fill(tester);
      final body = jsonDecode(patches().single.body) as Map<String, dynamic>;
      expect(body, {
        'current_password': 'old-password',
        'password': 'new-password',
      });
      expect(find.text('Password changed.'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(key('password-new')).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a wrong current password is said plainly', (tester) async {
      await mount(tester, (req) async {
        if (req.method == 'PATCH') {
          return jsonResponse({'detail': 'Current password is incorrect'}, 400);
        }
        return ok(req);
      });
      await fill(tester);
      expect(find.text('The current password is not right.'), findsOneWidget);
    });
  });

  testWidgets('Sign out goes back to the start and signs out', (tester) async {
    await mount(tester, ok);
    await tester.ensureVisible(key('sign-out'));
    await tester.tap(key('sign-out'));
    await tester.pumpAndSettle();
    expect(session.state, SessionState.signedOut);
    expect(find.text('Profile and settings'), findsNothing);
  });

  group('delete account', () {
    Future<void> openDialog(WidgetTester tester) async {
      await tester.ensureVisible(key('delete-account'));
      await tester.tap(key('delete-account'));
      await tester.pumpAndSettle();
    }

    testWidgets('needs DELETE typed, and Cancel deletes nothing', (
      tester,
    ) async {
      await mount(tester, ok);
      await openDialog(tester);
      expect(find.text('Delete your account?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(key('delete-confirm')).onPressed,
        isNull,
      );
      await tester.enterText(key('delete-confirm-field'), 'delete me');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(key('delete-confirm')).onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'DELETE'), isEmpty);
      expect(session.state, SessionState.signedIn);
    });

    testWidgets('deletes, wipes the phone and signs out', (tester) async {
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
        await d.add(SyncKind.readings, 's1', {'client_id': 'r1'});
        return d;
      }))!;
      addTearDown(() => db.close());
      await mount(tester, ok, openDb: () async => db);
      await openDialog(tester);
      await tester.enterText(key('delete-confirm-field'), 'DELETE');
      await tester.pump();
      await tester.tap(key('delete-confirm'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      final del = calls.singleWhere((c) => c.method == 'DELETE');
      expect(del.url.path, endsWith('/auth/me'));
      expect(session.state, SessionState.signedOut);
      expect(await tester.runAsync(() => db.activeFor('u1')), isNull);
      expect(await tester.runAsync(() => db.pendingCount()), 0);
      expect(find.text('Profile and settings'), findsNothing);
    });

    testWidgets('the last admin is told why it was refused', (tester) async {
      await mount(tester, (req) async {
        if (req.method == 'DELETE') {
          return jsonResponse({
            'detail': 'Cannot delete the last active admin',
          }, 409);
        }
        return ok(req);
      }, role: 'admin');
      await openDialog(tester);
      await tester.enterText(key('delete-confirm-field'), 'DELETE');
      await tester.pump();
      await tester.tap(key('delete-confirm'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not delete the account: Cannot delete the last active admin',
        ),
        findsOneWidget,
      );
      expect(session.state, SessionState.signedIn);
      expect(find.text('Profile and settings'), findsOneWidget);
    });

    testWidgets('offline keeps the account and says so', (tester) async {
      await mount(tester, (req) async {
        if (req.method == 'DELETE') throw http.ClientException('down');
        return ok(req);
      });
      await openDialog(tester);
      await tester.enterText(key('delete-confirm-field'), 'DELETE');
      await tester.pump();
      await tester.tap(key('delete-confirm'));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(session.state, SessionState.signedIn);
    });
  });

  testWidgets('a Viewer sees no consent line', (tester) async {
    await mount(tester, ok, role: 'viewer');
    expect(find.text('a@b.co · viewer'), findsOneWidget);
    expect(find.textContaining('Privacy consent'), findsNothing);
  });
}
