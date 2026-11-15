import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/data/api_client.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/screens/consent_screen.dart';
import 'package:signalscape_mobile/screens/privacy_notice.dart';
import 'package:signalscape_mobile/screens/sign_in_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'support.dart';

void tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<(Session, List<http.Request>)> pumpSignInHome(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
) async {
  tall(tester);
  final calls = <http.Request>[];
  final tokens = MemoryTokens();
  final session = Session(
    api: apiFor((req) async {
      calls.add(req);
      return handler(req);
    }),
    tokens: tokens,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: SignInScreen(session: session),
    ),
  );
  return (session, calls);
}

/// The sign-in radar never stops animating, so pumpAndSettle would time out
/// whenever that screen is showing.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> openRegister(WidgetTester tester) async {
  await tester.tap(find.text('Create an account'));
  await tester.pumpAndSettle();
}

Future<void> fillRegister(
  WidgetTester tester, {
  String name = 'Boon',
  String email = 'boon@b.co',
  String password = 'long-enough',
  String confirm = 'long-enough',
}) async {
  final fields = find.byType(TextFormField);
  await tester.enterText(fields.at(0), name);
  await tester.enterText(fields.at(1), email);
  await tester.enterText(fields.at(2), password);
  await tester.enterText(fields.at(3), confirm);
}

void main() {
  group('register screen', () {
    testWidgets('is reached from sign in', (tester) async {
      await pumpSignInHome(tester, (_) async => jsonResponse({}));
      await openRegister(tester);
      expect(find.text('NEW SURVEYOR'), findsOneWidget);
      expect(find.text('Create account'), findsWidgets);
    });

    testWidgets('checks every field before calling the API', (tester) async {
      final (_, calls) = await pumpSignInHome(
        tester,
        (_) async => jsonResponse({}),
      );
      await openRegister(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pump();
      expect(find.text('Enter your name.'), findsOneWidget);
      expect(find.text('Enter your email.'), findsOneWidget);
      expect(find.text('Use at least 8 characters.'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('passwords must match', (tester) async {
      final (_, calls) = await pumpSignInHome(
        tester,
        (_) async => jsonResponse({}),
      );
      await openRegister(tester);
      await fillRegister(tester, confirm: 'different-pass');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pump();
      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(calls, isEmpty);
    });

    testWidgets('creates the account, signs in and leaves the form', (
      tester,
    ) async {
      final (session, calls) = await pumpSignInHome(tester, (req) async {
        if (req.url.path.endsWith('/auth/register')) {
          return jsonResponse(userJson(consented: false), 201);
        }
        if (req.url.path.endsWith('/auth/login')) {
          return jsonResponse({'access_token': 'tok'});
        }
        return jsonResponse(userJson(consented: false));
      });
      await openRegister(tester);
      await fillRegister(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await settle(tester);
      expect(
        [for (final r in calls) r.url.path],
        ['/api/auth/register', '/api/auth/login', '/api/auth/me'],
      );
      expect(jsonDecode(calls.first.body), {
        'name': 'Boon',
        'email': 'boon@b.co',
        'password': 'long-enough',
      });
      expect(session.state, SessionState.signedIn);
      expect(session.user!.needsConsent, isTrue); // the consent screen is next
      expect(find.text('NEW SURVEYOR'), findsNothing);
    });

    testWidgets('a taken email says so', (tester) async {
      await pumpSignInHome(
        tester,
        (_) async =>
            jsonResponse({'detail': 'Email is already registered'}, 409),
      );
      await openRegister(tester);
      await fillRegister(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already has an account'), findsOneWidget);
    });

    testWidgets('can go back to sign in', (tester) async {
      await pumpSignInHome(tester, (_) async => jsonResponse({}));
      await openRegister(tester);
      await tester.tap(find.text('I already have an account'));
      await settle(tester);
      expect(find.text('NEW SURVEYOR'), findsNothing);
      expect(find.text('Sign in'), findsWidgets);
    });
  });

  group('consent screen', () {
    Future<(Session, List<http.Request>)> pumpConsent(
      WidgetTester tester,
    ) async {
      tall(tester);
      final calls = <http.Request>[];
      final session = signedIn((req) async {
        calls.add(req);
        if (req.url.path.endsWith('/consent')) return jsonResponse({});
        return jsonResponse(userJson());
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: ConsentScreen(session: session),
        ),
      );
      return (session, calls);
    }

    testWidgets('shows the whole privacy notice', (tester) async {
      await pumpConsent(tester);
      for (final s in privacyNotice) {
        expect(find.text(s.title, skipOffstage: false), findsOneWidget);
      }
      expect(
        find.textContaining('RA 10173', skipOffstage: false),
        findsWidgets,
      );
      expect(find.text(privacyNoticeVersion), findsOneWidget);
    });

    test('the notice covers what REQUIREMENTS section 9 promises', () {
      final all = privacyNotice.map((s) => '${s.title} ${s.body}').join(' ');
      for (final word in [
        'Data Privacy Act of 2012',
        'name, email',
        'hashed',
        'HTTPS',
        'view, export and delete',
        'floor plans',
        'only while you are running a survey',
        'BSSID',
        'No contacts',
        'not uploaded',
      ]) {
        expect(all.toLowerCase(), contains(word.toLowerCase()), reason: word);
      }
    });

    testWidgets('Agree stays off until the box is ticked', (tester) async {
      final (_, calls) = await pumpConsent(tester);
      final agree = find.widgetWithText(FilledButton, 'Agree and continue');
      await tester.ensureVisible(agree);
      expect(tester.widget<FilledButton>(agree).onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(tester.widget<FilledButton>(agree).onPressed, isNotNull);
      expect(calls, isEmpty);
    });

    testWidgets('agreeing records consent with the API', (tester) async {
      final (session, calls) = await pumpConsent(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Agree and continue'));
      await tester.pumpAndSettle();
      expect(calls.first.method, 'POST');
      expect(calls.first.url.path, '/api/auth/me/consent');
      expect(session.user!.consented, isTrue);
    });

    testWidgets('Not now signs out', (tester) async {
      final (session, _) = await pumpConsent(tester);
      final notNow = find.text('Not now');
      await tester.ensureVisible(notNow);
      await tester.tap(notNow);
      await tester.pumpAndSettle();
      expect(session.state, SessionState.signedOut);
    });

    testWidgets('an API error is shown and nothing is lost', (tester) async {
      tall(tester);
      final session = signedIn(
        (_) async => jsonResponse({'detail': 'Try later'}, 500),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: ConsentScreen(session: session),
        ),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Agree and continue'));
      await tester.pumpAndSettle();
      expect(find.text('Try later'), findsOneWidget);
    });
  });

  test('registering that works but cannot sign in says so', () async {
    final session = Session(
      api: apiFor((req) async {
        if (req.url.path.endsWith('/auth/register')) {
          return jsonResponse(userJson(), 201);
        }
        return jsonResponse({'detail': 'Inactive'}, 400);
      }),
      tokens: MemoryTokens(),
    );
    await expectLater(
      session.register('A', 'a@b.co', 'long-enough'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          contains('Account created'),
        ),
      ),
    );
  });
}
