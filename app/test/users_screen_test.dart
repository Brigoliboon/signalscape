import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/data/user_models.dart';
import 'package:signalscape_mobile/screens/buildings_screen.dart';
import 'package:signalscape_mobile/screens/users_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

Map<String, dynamic> person(
  String id,
  String name,
  String role, {
  bool active = true,
  bool consented = true,
}) => {
  'id': id,
  'email': '$name@x.test'.toLowerCase(),
  'name': name,
  'role': role,
  'is_active': active,
  'consented_at': consented ? '2026-11-01T00:00:00Z' : null,
  'good_threshold_dbm': -67,
  'dead_threshold_dbm': -80,
  'created_at': '2026-11-02T08:00:00Z',
  'updated_at': '2026-11-02T08:00:00Z',
};

void main() {
  late List<http.Request> calls;
  late List<Map<String, dynamic>> users;
  late Session session;

  Future<http.Response> Function(http.Request) server = (r) async =>
      http.Response('', 500);

  /// A small fake of `/users` that applies PATCH and DELETE to [users].
  Future<http.Response> fake(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/users') && req.method == 'GET') {
      final page = int.parse(req.url.queryParameters['page'] ?? '1');
      final size = int.parse(req.url.queryParameters['page_size'] ?? '20');
      final from = (page - 1) * size;
      final to = (from + size).clamp(0, users.length);
      return jsonResponse({
        'items': users.sublist(from.clamp(0, users.length), to),
        'total': users.length,
        'page': page,
        'page_size': size,
      });
    }
    final id = path.split('/').last;
    final i = users.indexWhere((u) => u['id'] == id);
    if (i < 0) return jsonResponse({'detail': 'Not found'}, 404);
    if (req.method == 'PATCH') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      if (body.containsKey('role')) users[i]['role'] = body['role'];
      if (body.containsKey('is_active')) {
        users[i]['is_active'] = body['is_active'];
      }
      return jsonResponse(users[i]);
    }
    if (req.method == 'DELETE') {
      users.removeAt(i);
      return http.Response('', 204);
    }
    return jsonResponse({'detail': 'Not found'}, 404);
  }

  Future<void> mount(
    WidgetTester tester, {
    int pageSize = 20,
    String role = 'admin',
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    calls = [];
    session = signedIn((req) async {
      calls.add(req);
      return server(req);
    }, role: role);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: UsersScreen(session: session, pageSize: pageSize),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  List<http.Request> sent(String method) =>
      calls.where((c) => c.method == method).toList();

  Future<void> openUser(WidgetTester tester, String id) async {
    await tester.tap(key('user-$id'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    users = [
      person('u1', 'Ada', 'admin'),
      person('u2', 'Ben', 'surveyor'),
      person('u3', 'Cy', 'viewer', active: false),
    ];
    server = fake;
  });

  testWidgets('lists the users with role, status and who you are', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('3 users'), findsOneWidget);
    expect(find.text('Ada (you)'), findsOneWidget);
    expect(find.textContaining('ada@x.test'), findsOneWidget);
    expect(find.textContaining('Surveyor'), findsWidgets);
    expect(find.textContaining('Viewer · Inactive'), findsOneWidget);
    final first = sent('GET').single;
    expect(first.url.queryParameters['sort'], '-created_at');
    expect(first.url.queryParameters.containsKey('role'), isFalse);
    expect(first.url.queryParameters.containsKey('is_active'), isFalse);
  });

  testWidgets('searching waits a moment, then asks the API', (tester) async {
    await mount(tester);
    await tester.enterText(key('user-search'), 'ben');
    await tester.pump(const Duration(milliseconds: 100));
    expect(sent('GET'), hasLength(1));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(sent('GET').last.url.queryParameters['q'], 'ben');
  });

  testWidgets('role chip, status and sort are sent as filters', (tester) async {
    await mount(tester);
    await tester.tap(key('role-viewer'));
    await tester.pump();
    await tester.pump();
    expect(sent('GET').last.url.queryParameters['role'], 'viewer');

    await tester.tap(key('role-any'));
    await tester.pump();
    await tester.pump();
    expect(sent('GET').last.url.queryParameters.containsKey('role'), isFalse);

    await tester.tap(key('user-status'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Inactive').last);
    await tester.pumpAndSettle();
    expect(sent('GET').last.url.queryParameters['is_active'], 'false');

    await tester.tap(key('user-sort'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name A–Z').last);
    await tester.pumpAndSettle();
    expect(sent('GET').last.url.queryParameters['sort'], 'name');
  });

  testWidgets('Load more fetches the next page', (tester) async {
    await mount(tester, pageSize: 2);
    expect(find.text('3 users'), findsOneWidget);
    expect(key('user-u3'), findsNothing);
    await tester.ensureVisible(key('user-more'));
    await tester.tap(key('user-more'));
    await tester.pumpAndSettle();
    expect(key('user-u3'), findsOneWidget);
    expect(sent('GET').last.url.queryParameters['page'], '2');
    expect(key('user-more'), findsNothing);
  });

  testWidgets('says so when nobody matches', (tester) async {
    users = [];
    await mount(tester);
    expect(key('user-empty'), findsOneWidget);
    expect(find.text('0 users'), findsOneWidget);
  });

  testWidgets('a failed load shows the reason and Try again works', (
    tester,
  ) async {
    var fail = true;
    server = (req) async {
      if (fail) return jsonResponse({'detail': 'Admin role required'}, 403);
      return fake(req);
    };
    await mount(tester);
    expect(find.text('Admin role required'), findsOneWidget);
    fail = false;
    await tester.tap(key('user-retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Admin role required'), findsNothing);
    expect(find.text('Ben'), findsOneWidget);
  });

  testWidgets('offline load says there is no connection', (tester) async {
    server = (req) async => throw http.ClientException('down');
    await mount(tester);
    expect(find.text('No connection to the server.'), findsOneWidget);
    expect(key('user-retry'), findsOneWidget);
  });

  group('role', () {
    testWidgets('changes a Surveyor to a Viewer without asking', (
      tester,
    ) async {
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('set-role-viewer'));
      await tester.pumpAndSettle();
      final body = jsonDecode(sent('PATCH').single.body) as Map;
      expect(body, {'role': 'viewer'});
      expect(find.textContaining('Viewer'), findsWidgets);
      expect(find.text('Ben is now a Viewer.'), findsOneWidget);
    });

    testWidgets('the current role chip does nothing', (tester) async {
      await mount(tester);
      await openUser(tester, 'u2');
      final chip = tester.widget<ChoiceChip>(key('set-role-surveyor'));
      expect(chip.onSelected, isNull);
    });

    testWidgets('demoting an Admin asks first; Cancel changes nothing', (
      tester,
    ) async {
      users.add(person('u4', 'Dee', 'admin'));
      await mount(tester);
      await openUser(tester, 'u4');
      await tester.tap(key('set-role-surveyor'));
      await tester.pumpAndSettle();
      expect(find.text('Make Dee a Surveyor?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent('PATCH'), isEmpty);

      await openUser(tester, 'u4');
      await tester.tap(key('set-role-surveyor'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(sent('PATCH'), hasLength(1));
      expect(users.last['role'], 'surveyor');
    });

    testWidgets('the API refusing is explained', (tester) async {
      users.add(person('u4', 'Dee', 'admin'));
      server = (req) async {
        if (req.method == 'PATCH') {
          return jsonResponse({
            'detail': 'Cannot demote or deactivate the last active admin',
          }, 409);
        }
        return fake(req);
      };
      await mount(tester);
      await openUser(tester, 'u4');
      await tester.tap(key('set-role-viewer'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Role not changed: Cannot demote or deactivate the last active admin',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Dee'), findsWidgets);
    });

    testWidgets('offline says nothing was changed', (tester) async {
      server = (req) async {
        if (req.method == 'PATCH') throw http.ClientException('down');
        return fake(req);
      };
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('set-role-viewer'));
      await tester.pumpAndSettle();
      expect(find.text("You're offline. Nothing was changed."), findsOneWidget);
    });
  });

  group('deactivate', () {
    testWidgets('asks first, then marks the account inactive', (tester) async {
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('toggle-active'));
      await tester.pumpAndSettle();
      expect(find.text('Deactivate Ben?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent('PATCH'), isEmpty);

      await openUser(tester, 'u2');
      await tester.tap(key('toggle-active'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(jsonDecode(sent('PATCH').single.body), {'is_active': false});
      expect(find.textContaining('Surveyor · Inactive'), findsOneWidget);
    });

    testWidgets('reactivating needs no confirmation', (tester) async {
      await mount(tester);
      await openUser(tester, 'u3');
      expect(find.text('Reactivate account'), findsOneWidget);
      await tester.tap(key('toggle-active'));
      await tester.pumpAndSettle();
      expect(jsonDecode(sent('PATCH').single.body), {'is_active': true});
      expect(find.text('Cy is active again.'), findsOneWidget);
      expect(find.textContaining('Viewer · Inactive'), findsNothing);
    });

    testWidgets('a refusal is explained', (tester) async {
      server = (req) async {
        if (req.method == 'PATCH') {
          return jsonResponse({'detail': 'Nope'}, 409);
        }
        return fake(req);
      };
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('toggle-active'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(find.text('Not deactivated: Nope'), findsOneWidget);
    });
  });

  group('delete', () {
    testWidgets('asks first; Cancel keeps the user', (tester) async {
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('delete-user'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Ben?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent('DELETE'), isEmpty);
      expect(key('user-u2'), findsOneWidget);
    });

    testWidgets('confirming removes the user from the list', (tester) async {
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('delete-user'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(sent('DELETE').single.url.path, endsWith('/users/u2'));
      expect(key('user-u2'), findsNothing);
      expect(find.text('2 users'), findsOneWidget);
      expect(find.text('Ben was deleted.'), findsOneWidget);
    });

    testWidgets('the last Admin is told why it was refused', (tester) async {
      server = (req) async {
        if (req.method == 'DELETE') {
          return jsonResponse({
            'detail': 'Cannot delete the last active admin',
          }, 409);
        }
        return fake(req);
      };
      users.add(person('u4', 'Dee', 'admin'));
      await mount(tester);
      await openUser(tester, 'u4');
      await tester.tap(key('delete-user'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(
        find.text('Not deleted: Cannot delete the last active admin'),
        findsOneWidget,
      );
      expect(key('user-u4'), findsOneWidget);
    });

    testWidgets('offline keeps the user and says so', (tester) async {
      server = (req) async {
        if (req.method == 'DELETE') throw http.ClientException('down');
        return fake(req);
      };
      await mount(tester);
      await openUser(tester, 'u2');
      await tester.tap(key('delete-user'));
      await tester.pumpAndSettle();
      await tester.tap(key('confirm-action'));
      await tester.pumpAndSettle();
      expect(find.text("You're offline. Nothing was changed."), findsOneWidget);
      expect(key('user-u2'), findsOneWidget);
    });
  });

  testWidgets('your own account has no delete, deactivate or role change', (
    tester,
  ) async {
    await mount(tester);
    await openUser(tester, 'u1');
    expect(key('self-note'), findsOneWidget);
    expect(key('delete-user'), findsNothing);
    expect(key('toggle-active'), findsNothing);
    expect(
      tester.widget<ChoiceChip>(key('set-role-viewer')).onSelected,
      isNull,
    );
  });

  group('entry from the home screen', () {
    Future<void> home(WidgetTester tester, String role) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      session = signedIn((req) async {
        if (req.url.path.endsWith('/buildings')) {
          return jsonResponse({
            'items': <Object>[],
            'total': 0,
            'page': 1,
            'page_size': 20,
          });
        }
        return fake(req);
      }, role: role);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: BuildingsScreen(session: session, checkUnfinished: false),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an Admin can open Manage users', (tester) async {
      await home(tester, 'admin');
      await tester.tap(key('open-users'));
      await tester.pumpAndSettle();
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('3 users'), findsOneWidget);
    });

    for (final role in ['surveyor', 'viewer']) {
      testWidgets('a $role does not see it', (tester) async {
        await home(tester, role);
        expect(key('open-users'), findsNothing);
        expect(find.text('Manage users'), findsNothing);
      });
    }
  });

  test('canManageUsers is for Admins only', () {
    expect(canManageUsers('admin'), isTrue);
    expect(canManageUsers('surveyor'), isFalse);
    expect(canManageUsers('viewer'), isFalse);
  });

  test('a user row reads the API fields', () {
    final u = AdminUser.fromJson(person('u9', 'Zed', 'viewer', active: false));
    expect(u.isActive, isFalse);
    expect(u.consented, isTrue);
    expect(u.createdAt!.year, 2026);
    expect(roleLabel('surveyor'), 'Surveyor');
    expect(roleLabel('odd'), 'odd');
  });
}
