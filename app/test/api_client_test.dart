import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:signalscape_mobile/core/sync_engine.dart';
import 'package:signalscape_mobile/data/api_client.dart';

ApiClient clientFor(MockClientHandler handler) =>
    ApiClient(client: MockClient(handler), baseUrl: 'https://example.test/');

PendingBatch batch() => PendingBatch(
  surveyId: 's1',
  kind: SyncKind.readings,
  ids: ['a'],
  items: [
    {'client_id': 'a'},
  ],
);

void main() {
  test('the default base URL is the live API', () {
    expect(ApiClient().baseUrl, 'https://signalscape.boonbrigoli.site');
  });

  test('login posts the form the API expects and returns the token', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return http.Response(jsonEncode({'access_token': 'tok'}), 200);
    });
    expect(await api.login(' a@b.co ', 'pw'), 'tok');
    expect(seen.url.toString(), 'https://example.test/api/auth/login');
    expect(seen.bodyFields, {'username': 'a@b.co', 'password': 'pw'});
  });

  test('requests carry the bearer token', () async {
    String? auth;
    final api = clientFor((req) async {
      auth = req.headers['Authorization'];
      return http.Response(jsonEncode({'items': []}), 200);
    })..token = 'tok';
    await api.buildings();
    expect(auth, 'Bearer tok');
  });

  test('API errors become readable messages', () async {
    final api = clientFor(
      (_) async => http.Response(jsonEncode({'detail': 'Nope'}), 403),
    );
    await expectLater(
      api.giveConsent(),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 403)
            .having((e) => e.message, 'message', 'Nope'),
      ),
    );
  });

  test('validation errors show the first message', () async {
    final api = clientFor(
      (_) async => http.Response(
        jsonEncode({
          'detail': [
            {'msg': 'Field required'},
          ],
        }),
        422,
      ),
    );
    await expectLater(
      api.createBuilding('x'),
      throwsA(
        isA<ApiException>().having((e) => e.message, 'msg', 'Field required'),
      ),
    );
  });

  test('a 401 with a token tells the app to sign in again', () async {
    var called = false;
    final api = clientFor((_) async => http.Response('{}', 401))
      ..token = 'old'
      ..onUnauthorized = () => called = true;
    await expectLater(api.me(), throwsA(isA<ApiException>()));
    expect(called, isTrue);
  });

  test('no network is a status-0 error', () async {
    final api = clientFor((_) async => throw const SocketException('down'));
    await expectLater(
      api.me(),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true)),
    );
  });

  test('the viewer address keeps the token in the fragment', () {
    final api = clientFor((_) async => http.Response('{}', 200))
      ..token = 'a.b.c';
    final uri = api.viewerUri('abc-123');
    expect(uri.path, '/api/viewer/');
    expect(uri.query, isEmpty);
    expect(uri.fragment, 'survey=abc-123&token=a.b.c');
  });

  test('readings go to the readings endpoint as {"readings": [...]}', () async {
    late http.Request seen;
    final api = clientFor((req) async {
      seen = req;
      return http.Response(jsonEncode({'inserted': 1, 'skipped': 0}), 200);
    });
    await api.postBatch(batch());
    expect(seen.url.path, '/api/surveys/s1/readings');
    expect(jsonDecode(seen.body), {
      'readings': [
        {'client_id': 'a'},
      ],
    });
  });

  group('ApiSyncTransport sorts failures', () {
    Future<SyncException> failWith(int status) async {
      final transport = ApiSyncTransport(
        clientFor((_) async => http.Response('{"detail":"x"}', status)),
      );
      try {
        await transport.send(batch());
      } on SyncException catch (e) {
        return e;
      }
      fail('expected a failure');
    }

    test('5xx, 408 and 429 are retried', () async {
      for (final s in [500, 502, 503, 408, 429]) {
        expect((await failWith(s)).retryable, isTrue, reason: '$s');
      }
    });

    test('other 4xx need a person', () async {
      for (final s in [400, 401, 403, 404, 409, 422]) {
        expect((await failWith(s)).retryable, isFalse, reason: '$s');
      }
    });

    test('no network is retried', () async {
      final transport = ApiSyncTransport(
        clientFor((_) async => throw const SocketException('down')),
      );
      await expectLater(
        transport.send(batch()),
        throwsA(isA<SyncException>().having((e) => e.retryable, 'r', true)),
      );
    });
  });
}
