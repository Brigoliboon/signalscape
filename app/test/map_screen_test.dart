import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/map_tiles.dart';
import 'package:signalscape_mobile/screens/map_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'map_data_test.dart' show ap, cell, collection, summary, trailJson;
import 'support.dart';

/// A 1x1 transparent PNG, so no tile ever comes from the network.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

class NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_png);
}

typedef Routes = Map<String, http.Response Function()>;

Routes goodRoutes() => {
  'GET /api/surveys/s1/summary': () => jsonResponse(summary()),
  'GET /api/surveys/s1/geojson': () => jsonResponse(
    collection([
      cell(121.0, 14.6, -50, 0, level: 'good'),
      cell(121.00001, 14.6, -90, 0, level: 'dead'),
      ap(121.0001, 14.6001, 0),
      cell(121.0, 14.6, -70, 1, level: 'fair'),
    ]),
  ),
  'GET /api/surveys/s1/trail': () => jsonResponse(trailJson()),
};

Future<List<String>> pump(
  WidgetTester tester,
  Routes routes, {
  bool canProcess = false,
  void Function(BuildContext)? onOpen3d,
}) async {
  final calls = <String>[];
  final api = apiFor((req) async {
    final key = '${req.method} ${req.url.path}';
    calls.add(key);
    final r = routes[key];
    return r == null ? http.Response('{"detail":"Not found"}', 404) : r();
  });
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: MapScreen(
        api: api,
        surveyId: 's1',
        canProcess: canProcess,
        tiles: MapTiles.forToken(''),
        tileProvider: NoTiles(),
        onOpen3d: onOpen3d,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  testWidgets('shows the map with floors, legend and attribution', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(PolygonLayer), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    // Opens on the floor with the most coverage (ground has two cells).
    final polygons = tester.widget<PolygonLayer>(find.byType(PolygonLayer));
    expect(polygons.polygons, hasLength(2));
    expect(find.text('Ground'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    // The surveyor's thresholds are in the legend.
    expect(find.text('Good ≥ -60 dBm'), findsOneWidget);
    expect(find.text('Dead < -75 dBm'), findsOneWidget);
    // Start marker and the access point are on this floor.
    expect(find.byKey(const ValueKey('pin-S')), findsOneWidget);
    expect(find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-E')), findsNothing);
  });

  testWidgets('switching floor shows only that floor\'s layers', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    await tester.tap(find.byKey(const ValueKey('floor-1')));
    await tester.pumpAndSettle();
    final polygons = tester.widget<PolygonLayer>(find.byType(PolygonLayer));
    expect(polygons.polygons, hasLength(1));
    expect(find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')), findsNothing);
    expect(find.byKey(const ValueKey('pin-S')), findsNothing);
    expect(find.byKey(const ValueKey('pin-E')), findsOneWidget);
  });

  testWidgets('layers can be switched off', (tester) async {
    await pump(tester, goodRoutes());
    await tester.tap(find.byKey(const ValueKey('layer-cells')));
    await tester.tap(find.byKey(const ValueKey('layer-aps')));
    await tester.tap(find.byKey(const ValueKey('layer-trail')));
    await tester.pumpAndSettle();
    expect(find.byType(PolygonLayer), findsNothing);
    expect(find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')), findsNothing);
    expect(find.byKey(const ValueKey('pin-S')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('layer-cells')));
    await tester.pumpAndSettle();
    expect(find.byType(PolygonLayer), findsOneWidget);
  });

  testWidgets('tapping an access point shows its SSID, BSSID and RSSI', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    await tester.tap(find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')));
    await tester.pumpAndSettle();
    expect(find.text('Lab'), findsWidgets);
    expect(find.text('BSSID aa:bb:cc:dd:ee:01'), findsOneWidget);
    expect(find.textContaining('-48 dBm'), findsOneWidget);
    expect(find.textContaining('7 readings'), findsOneWidget);
  });

  testWidgets('the map still shows without a trail', (tester) async {
    final routes = goodRoutes();
    routes.remove('GET /api/surveys/s1/trail');
    await pump(tester, routes);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byKey(const ValueKey('pin-S')), findsNothing);
  });

  testWidgets('a single floor has no selector', (tester) async {
    final routes = goodRoutes();
    routes['GET /api/surveys/s1/geojson'] = () =>
        jsonResponse(collection([cell(121.0, 14.6, -50, 0, level: 'good')]));
    routes['GET /api/surveys/s1/trail'] = () =>
        jsonResponse({'start': null, 'end': null, 'floors': []});
    routes['GET /api/surveys/s1/summary'] = () => jsonResponse({'floors': []});
    await pump(tester, routes);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Level 0'), findsOneWidget);
  });

  testWidgets('the 3D switch is offered when given', (tester) async {
    BuildContext? got;
    await pump(tester, goodRoutes(), onOpen3d: (c) => got = c);
    await tester.tap(find.text('3D view'));
    expect(got, isNotNull);
  });

  testWidgets('not processed: a clear message, no processing for viewers', (
    tester,
  ) async {
    await pump(tester, {
      'GET /api/surveys/s1/summary': () =>
          jsonResponse({'detail': 'Process this survey first'}, 409),
    });
    expect(find.text('Not processed yet'), findsOneWidget);
    expect(find.textContaining('Ask the surveyor'), findsOneWidget);
    expect(find.text('Process now'), findsNothing);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('not processed: a surveyor can process it and see the map', (
    tester,
  ) async {
    var processed = false;
    final routes = goodRoutes();
    final good = routes['GET /api/surveys/s1/summary']!;
    routes['GET /api/surveys/s1/summary'] = () => processed
        ? good()
        : jsonResponse({'detail': 'Process this survey first'}, 409);
    routes['POST /api/surveys/s1/process'] = () {
      processed = true;
      return jsonResponse({});
    };
    final calls = await pump(tester, routes, canProcess: true);
    expect(find.text('Process now'), findsOneWidget);
    await tester.tap(find.text('Process now'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /api/surveys/s1/process'));
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets('a failed processing says why and stays', (tester) async {
    await pump(tester, {
      'GET /api/surveys/s1/summary': () =>
          jsonResponse({'detail': 'Process this survey first'}, 409),
      'POST /api/surveys/s1/process': () =>
          jsonResponse({'detail': 'The survey is not completed'}, 409),
    }, canProcess: true);
    await tester.tap(find.text('Process now'));
    await tester.pumpAndSettle();
    expect(find.text('The survey is not completed'), findsOneWidget);
    expect(find.text('Process now'), findsOneWidget);
  });

  testWidgets('empty results say so', (tester) async {
    await pump(tester, {
      'GET /api/surveys/s1/summary': () => jsonResponse({'floors': []}),
      'GET /api/surveys/s1/geojson': () => jsonResponse(collection([])),
      'GET /api/surveys/s1/trail': () =>
          jsonResponse({'start': null, 'end': null, 'floors': []}),
    });
    expect(find.text('Nothing to show'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('a server error can be retried', (tester) async {
    var ok = false;
    final routes = goodRoutes();
    final good = routes['GET /api/surveys/s1/summary']!;
    routes['GET /api/surveys/s1/summary'] = () =>
        ok ? good() : jsonResponse({'detail': 'Boom'}, 500);
    await pump(tester, routes);
    expect(find.text("Couldn't load the map"), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
    ok = true;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsOneWidget);
  });

  testWidgets('offline is explained', (tester) async {
    final api = apiFor((req) async => throw http.ClientException('down'));
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MapScreen(
          api: api,
          surveyId: 's1',
          tiles: MapTiles.forToken(''),
          tileProvider: NoTiles(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.textContaining('needs a connection'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('Mapbox tiles credit Mapbox and OpenStreetMap', (tester) async {
    final api = apiFor((req) async {
      final r = goodRoutes()['${req.method} ${req.url.path}'];
      return r == null ? http.Response('{}', 404) : r();
    });
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MapScreen(
          api: api,
          surveyId: 's1',
          tiles: MapTiles.forToken('pk.test'),
          tileProvider: NoTiles(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('© Mapbox © OpenStreetMap contributors'), findsOneWidget);
  });
}
