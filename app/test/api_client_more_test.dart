import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/data/api_client.dart';

import 'support.dart';

void main() {
  test('register posts name, email and password', () async {
    late http.Request seen;
    final api = apiFor((req) async {
      seen = req;
      return jsonResponse(userJson(), 201);
    });
    await api.register(' Boon ', ' a@b.co ', 'secret-pass');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/auth/register');
    expect(jsonDecode(seen.body), {
      'name': 'Boon',
      'email': 'a@b.co',
      'password': 'secret-pass',
    });
  });

  test('a taken email comes back as a 409 with the API message', () async {
    final api = apiFor(
      (_) async => jsonResponse({'detail': 'Email is already registered'}, 409),
    );
    await expectLater(
      api.register('A', 'a@b.co', 'secret-pass'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'status', 409)
            .having((e) => e.message, 'message', 'Email is already registered'),
      ),
    );
  });

  test(
    'buildingPage sends search, paging and sort, and reads the page',
    () async {
      late Uri seen;
      final api = apiFor((req) async {
        seen = req.url;
        return jsonResponse({
          'items': [buildingJson('b1', 'Main', address: '1 Road')],
          'total': 41,
          'page': 2,
          'page_size': 20,
        });
      });
      final page = await api.buildingPage(
        q: ' tower ',
        page: 2,
        pageSize: 20,
        sort: '-created_at',
      );
      expect(seen.path, '/api/buildings');
      expect(seen.queryParameters, {
        'q': 'tower',
        'page': '2',
        'page_size': '20',
        'sort': '-created_at',
      });
      expect(page.items.single.address, '1 Road');
      expect(page.total, 41);
      expect(page.hasMore, isTrue);
    },
  );

  test('buildingPage leaves q out when the search is empty', () async {
    late Uri seen;
    final api = apiFor((req) async {
      seen = req.url;
      return jsonResponse({
        'items': [],
        'total': 0,
        'page': 1,
        'page_size': 20,
      });
    });
    final page = await api.buildingPage(q: '  ');
    expect(seen.queryParameters.containsKey('q'), isFalse);
    expect(page.hasMore, isFalse);
  });

  test('createBuilding and updateBuilding send the right bodies', () async {
    final bodies = <String, Object?>{};
    final api = apiFor((req) async {
      bodies[req.method] = jsonDecode(req.body);
      return jsonResponse(
        buildingJson('b1', 'Main'),
        req.method == 'POST' ? 201 : 200,
      );
    });
    await api.createBuilding('Main', address: '1 Road');
    await api.updateBuilding(
      'b1',
      name: 'Main',
      address: null,
      description: 'd',
    );
    expect(bodies['POST'], {'name': 'Main', 'address': '1 Road'});
    // Update sends every field so an emptied address is cleared.
    expect(bodies['PATCH'], {
      'name': 'Main',
      'address': null,
      'description': 'd',
    });
  });

  test(
    'createFloor sends the height and only the sizes that were given',
    () async {
      late Map<String, dynamic> body;
      final api = apiFor((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.url.path, '/api/buildings/b1/floors');
        return jsonResponse(floorJson('f1', 1, 'Floor 1', height: 3.4), 201);
      });
      final floor = await api.createFloor('b1', 1, 'Floor 1', heightM: 3.4);
      expect(body, {'level': 1, 'label': 'Floor 1', 'height_m': 3.4});
      expect(floor.heightM, 3.4);
    },
  );

  test('updateFloor sends every field', () async {
    late Map<String, dynamic> body;
    final api = apiFor((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(req.method, 'PATCH');
      expect(req.url.path, '/api/floors/f1');
      return jsonResponse(floorJson('f1', 2, 'Two'));
    });
    await api.updateFloor(
      'f1',
      level: 2,
      label: 'Two',
      heightM: 3.1,
      widthM: 20,
    );
    expect(body, {
      'level': 2,
      'label': 'Two',
      'height_m': 3.1,
      'width_m': 20.0,
      'length_m': null,
    });
  });

  test(
    'uploadPlan sends a multipart PUT with the file and the token',
    () async {
      late http.Request seen;
      final api = apiFor((req) async {
        seen = req;
        return jsonResponse(
          floorJson('f1', 0, 'Ground', planUrl: '/api/floors/f1/plan'),
        );
      })..token = 'tok';
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
      final floor = await api.uploadPlan('f1', png, 'image/png');
      expect(seen.method, 'PUT');
      expect(seen.url.path, '/api/floors/f1/plan');
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['content-type'], startsWith('multipart/form-data'));
      final text = latin1.decode(seen.bodyBytes);
      expect(text, contains('name="file"'));
      expect(text, contains('filename="plan.png"'));
      expect(text, contains('image/png'));
      expect(floor.hasPlan, isTrue);
    },
  );

  test('uploadPlan reports the API refusal', () async {
    final api = apiFor(
      (_) async =>
          jsonResponse({'detail': 'Floor plan must be at most 5 MB'}, 413),
    );
    await expectLater(
      api.uploadPlan('f1', [0xFF, 0xD8, 0xFF], 'image/jpeg'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.message,
          'message',
          'Floor plan must be at most 5 MB',
        ),
      ),
    );
  });

  test('processPreview asks for a preview of one floor', () async {
    late http.Request seen;
    final api = apiFor((req) async {
      seen = req;
      return jsonResponse({'preview': true, 'grids': []});
    });
    final json = await api.processPreview('s1', 'f1');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/surveys/s1/process');
    expect(seen.url.queryParameters, {'preview': 'true', 'floor_id': 'f1'});
    expect(json['preview'], isTrue);
  });

  test('createSurvey says whether the phone has a barometer', () async {
    late Map<String, dynamic> body;
    final api = apiFor((req) async {
      body = jsonDecode(req.body) as Map<String, dynamic>;
      return jsonResponse({'id': 's1'}, 201);
    });
    await api.createSurvey(
      buildingId: 'b1',
      originLat: 1,
      originLng: 2,
      originAccuracyM: 3,
      hasBarometer: true,
    );
    expect(body['has_barometer'], isTrue);
  });

  test('the plan address and headers let an image widget fetch it', () {
    final api = apiFor((_) async => jsonResponse({}))..token = 'tok';
    expect(
      api.planUri('/api/floors/f1/plan').toString(),
      'https://x.test/api/floors/f1/plan',
    );
    expect(api.authHeaders, {'Authorization': 'Bearer tok'});
  });
}
