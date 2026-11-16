import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/map_tiles.dart';

void main() {
  test('with no token the map uses OpenStreetMap and credits it', () {
    for (final token in ['', '   ']) {
      final t = MapTiles.forToken(token);
      expect(t.usesMapbox, isFalse);
      expect(t.urlTemplate, 'https://tile.openstreetmap.org/{z}/{x}/{y}.png');
      expect(t.attribution, contains('OpenStreetMap'));
      expect(t.attribution, isNot(contains('Mapbox')));
      expect(t.tileDimension, 256);
      expect(t.zoomOffset, 0);
      expect(t.additionalOptions, isEmpty);
    }
  });

  test('with a token it uses Mapbox satellite 512 px tiles and credits both', () {
    final t = MapTiles.forToken(' pk.test ');
    expect(t.usesMapbox, isTrue);
    expect(
      t.urlTemplate,
      'https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/512/'
      '{z}/{x}/{y}?access_token={accessToken}',
    );
    expect(t.additionalOptions, {'accessToken': 'pk.test'});
    expect(t.tileDimension, 512);
    expect(t.zoomOffset, -1);
    expect(t.attribution, contains('Mapbox'));
    expect(t.attribution, contains('OpenStreetMap'));
  });

  test('the style can be chosen', () {
    final t = MapTiles.forToken('pk.x', style: 'dark-v11');
    expect(t.urlTemplate, contains('/mapbox/dark-v11/'));
  });

  test('a build without a define falls back to OpenStreetMap', () {
    // The test run passes no MAPBOX_TOKEN, and none is ever committed.
    expect(MapTiles.current().usesMapbox, isFalse);
  });

  test('the three looks use the right Mapbox styles', () {
    expect(MapStyle.values.map((s) => s.mapboxId), [
      'satellite-streets-v12',
      'light-v11',
      'dark-v11',
    ]);
    expect(MapStyle.values.map((s) => s.label), [
      'Satellite',
      'Streets light',
      'Streets dark',
    ]);
  });

  test('withStyle keeps the token and changes only the style', () {
    final base = MapTiles.forToken('pk.x');
    for (final style in MapStyle.values) {
      final t = base.withStyle(style);
      expect(t.urlTemplate, contains('/mapbox/${style.mapboxId}/'));
      expect(t.additionalOptions, {'accessToken': 'pk.x'});
      expect(t.tileDimension, 512);
      expect(t.usesMapbox, isTrue);
    }
  });

  test('without a token every style is the OpenStreetMap map', () {
    final base = MapTiles.forToken('');
    for (final style in MapStyle.values) {
      final t = base.withStyle(style);
      expect(t.usesMapbox, isFalse);
      expect(t.urlTemplate, base.urlTemplate);
    }
  });
}
