import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:signalscape_mobile/data/api_client.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/data/token_store.dart';
import 'package:signalscape_mobile/screens/sign_in_screen.dart';
import 'package:signalscape_mobile/theme.dart';

class MemoryTokens extends TokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

const _userJson = {
  'id': 'u1',
  'email': 'a@b.co',
  'name': 'A',
  'role': 'admin',
  'is_active': true,
  'consented_at': null,
  'good_threshold_dbm': -67,
  'dead_threshold_dbm': -80,
};

Future<(Session, MemoryTokens)> pumpSignIn(
  WidgetTester tester,
  MockClientHandler handler,
) async {
  final tokens = MemoryTokens();
  final session = Session(
    api: ApiClient(client: MockClient(handler), baseUrl: 'https://x.test'),
    tokens: tokens,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: SignInScreen(session: session),
    ),
  );
  return (session, tokens);
}

void main() {
  testWidgets('asks for both fields before calling the API', (tester) async {
    var calls = 0;
    await pumpSignIn(tester, (_) async {
      calls++;
      return http.Response('{}', 200);
    });
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.text('Enter your email and password.'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('a wrong password shows a plain message', (tester) async {
    await pumpSignIn(tester, (_) async => http.Response('{"detail":"x"}', 401));
    await tester.enterText(find.byType(TextField).first, 'a@b.co');
    await tester.enterText(find.byType(TextField).last, 'nope');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Wrong email or password.'), findsOneWidget);
  });

  testWidgets('signing in stores the token and loads the profile', (
    tester,
  ) async {
    final (session, tokens) = await pumpSignIn(tester, (req) async {
      if (req.url.path.endsWith('/auth/login')) {
        return http.Response(jsonEncode({'access_token': 'tok'}), 200);
      }
      return http.Response(jsonEncode(_userJson), 200);
    });
    await tester.enterText(find.byType(TextField).first, 'a@b.co');
    await tester.enterText(find.byType(TextField).last, 'secret-pw');
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump();
    expect(session.state, SessionState.signedIn);
    expect(session.user!.role, 'admin');
    expect(session.user!.needsConsent, isFalse); // only Surveyors are asked
    expect(tokens.value, 'tok');
    expect(session.api.token, 'tok');
  });

  testWidgets('buttons meet the 48 dp touch target', (tester) async {
    await pumpSignIn(tester, (_) async => http.Response('{}', 200));
    expect(
      tester.getSize(find.byType(FilledButton)).height,
      greaterThanOrEqualTo(kTarget),
    );
  });

  test('text colours pass WCAG AA on the dark surfaces', () {
    double lum(Color c) {
      double ch(double v) => v <= 0.03928
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    double contrast(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      return (la > lb ? la + 0.05 : lb + 0.05) /
          (la > lb ? lb + 0.05 : la + 0.05);
    }

    for (final bg in [
      AppColors.background,
      AppColors.surface,
      AppColors.surfaceHigh,
    ]) {
      for (final fg in [
        AppColors.textPrimary,
        AppColors.textMuted,
        AppColors.accent,
        AppColors.good,
        AppColors.fair,
        AppColors.dead,
      ]) {
        expect(
          contrast(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '$fg on $bg',
        );
      }
    }
    expect(
      contrast(AppColors.onPrimary, AppColors.primary),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(AppColors.onPrimary, AppColors.danger),
      greaterThanOrEqualTo(4.5),
    );
  });
}
