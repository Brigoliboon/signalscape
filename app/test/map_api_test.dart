import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

void main() {
  test('networks are read page by page until the total is reached', () async {
    final pages = <String>[];
    final api = apiFor((req) async {
      expect(req.url.path, '/api/surveys/s1/networks');
      expect(req.url.queryParameters['sort'], '-reading_count');
      expect(req.url.queryParameters['page_size'], '100');
      final page = int.parse(req.url.queryParameters['page']!);
      pages.add('$page');
      return jsonResponse({
        'items': [
          for (var i = 0; i < (page == 1 ? 100 : 20); i++)
            {'ssid': 's', 'bssid': 'b$page-$i', 'reading_count': 1},
        ],
        'total': 120,
        'page': page,
        'page_size': 100,
      });
    });
    final items = await api.surveyNetworks('s1');
    expect(items, hasLength(120));
    expect(pages, ['1', '2']);
  });

  test('an empty page ends the loop', () async {
    var calls = 0;
    final api = apiFor((req) async {
      calls++;
      return jsonResponse({
        'items': <Object>[],
        'total': 5,
        'page': 1,
        'page_size': 100,
      });
    });
    expect(await api.surveyNetworks('s1'), isEmpty);
    expect(calls, 1);
  });

  test('geojson passes the BSSID filter only when given', () async {
    final seen = <Map<String, String>>[];
    final api = apiFor((req) async {
      seen.add(req.url.queryParameters);
      return http.Response('{"type":"FeatureCollection","features":[]}', 200);
    });
    await api.surveyGeoJson('s1');
    await api.surveyGeoJson('s1', bssid: 'aa:bb:cc:dd:ee:01');
    expect(seen[0], isEmpty);
    expect(seen[1], {'bssid': 'aa:bb:cc:dd:ee:01'});
  });
}
