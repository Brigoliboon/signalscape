import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/geo.dart';

void main() {
  const lat0 = 14.5995;
  const lng0 = 120.9842;

  test('origin maps to zero', () {
    final p = toLocal(lat0, lng0, lat0, lng0);
    expect(p.x, 0);
    expect(p.y, 0);
  });

  test('north and east are positive y and x', () {
    final g = toGeo(10, 20, lat0, lng0);
    expect(g.lat, greaterThan(lat0));
    expect(g.lng, greaterThan(lng0));
  });

  test('one degree of latitude is about 111 km', () {
    final p = toLocal(lat0 + 1, lng0, lat0, lng0);
    expect(p.y, closeTo(111195, 50));
    expect(p.x, closeTo(0, 1e-9));
  });

  test('round trip is exact to well under a millimetre', () {
    for (final (x, y) in [(0.0, 0.0), (12.5, -7.25), (-300.0, 250.0)]) {
      final g = toGeo(x, y, lat0, lng0);
      final back = toLocal(g.lat, g.lng, lat0, lng0);
      expect(back.x, closeTo(x, 1e-6));
      expect(back.y, closeTo(y, 1e-6));
    }
  });

  test('same numbers as the API for a known point', () {
    // api/app/services/processing.py: to_geo(30, 15, 14.5995, 120.9842)
    final g = toGeo(30, 15, lat0, lng0);
    expect(g.lat, closeTo(14.599634898, 1e-8));
    expect(g.lng, closeTo(120.984478798, 1e-8));
  });
}
