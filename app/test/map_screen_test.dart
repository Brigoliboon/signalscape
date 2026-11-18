import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/heatmap.dart';
import 'package:signalscape_mobile/core/map_tiles.dart';
import 'package:signalscape_mobile/data/api_client.dart';
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

/// What the screen asked to have drawn, newest last. The renderer answers at
/// once, so no isolate is involved.
final List<HeatRequest> heatRequests = [];

Future<HeatImage> fakeHeat(HeatRequest request) async {
  heatRequests.add(request);
  return renderHeatPng(request);
}

/// How many cells of data the newest picture was made from.
int drawnCells() => heatRequests.last.grid.values.whereType<double>().length;

OverlayImage overlayOf(WidgetTester tester) =>
    tester
            .widget<OverlayImageLayer>(find.byType(OverlayImageLayer))
            .overlayImages
            .single
        as OverlayImage;

Routes goodRoutes() => {
  'GET /api/surveys/s1/summary': () => jsonResponse(summary()),
  'GET /api/surveys/s1/geojson': () => jsonResponse(
    collection([
      cell(121.0, 14.6, -50, 0, level: 'good'),
      cell(121.00001, 14.6, -90, 0, level: 'dead', confidence: 0.0),
      ap(121.0001, 14.6001, 0),
      cell(121.0, 14.6, -70, 1, level: 'fair'),
    ]),
  ),
  'GET /api/surveys/s1/trail': () => jsonResponse(trailJson()),
  'GET /api/surveys/s1/networks': () => jsonResponse({
    'items': [
      {
        'ssid': 'Lab',
        'bssid': 'aa:bb:cc:dd:ee:01',
        'reading_count': 40,
        'max_rssi_dbm': -48,
      },
      {
        'ssid': '',
        'bssid': 'aa:bb:cc:dd:ee:02',
        'reading_count': 12,
        'max_rssi_dbm': -70,
      },
      // The same BSSID under another SSID is listed once.
      {
        'ssid': 'Lab-guest',
        'bssid': 'aa:bb:cc:dd:ee:01',
        'reading_count': 3,
        'max_rssi_dbm': -50,
      },
    ],
    'total': 3,
    'page': 1,
    'page_size': 100,
  }),
  // One network: two cells and its access point on the ground floor only.
  'GET /api/surveys/s1/geojson?bssid=aa:bb:cc:dd:ee:01': () => jsonResponse(
    collection([
      cell(121.0, 14.6, -55, 0, level: 'good'),
      ap(121.0001, 14.6001, 0),
    ]),
  ),
  // Another network: nothing on any floor.
  'GET /api/surveys/s1/geojson?bssid=aa:bb:cc:dd:ee:02': () =>
      jsonResponse(collection([])),
};

Future<List<String>> pump(
  WidgetTester tester,
  Routes routes, {
  bool canProcess = false,
  void Function(BuildContext)? onOpen3d,
}) async {
  heatRequests.clear();
  final calls = <String>[];
  final api = apiFor((req) async {
    final bssid = req.url.queryParameters['bssid'];
    final key =
        '${req.method} ${req.url.path}${bssid == null ? '' : '?bssid=$bssid'}';
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
        heatRenderer: fakeHeat,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

Future<void> pumpWith(
  WidgetTester tester,
  ApiClient api, {
  MapTiles? tiles,
  double width = 800,
}) async {
  heatRequests.clear();
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: MapScreen(
        api: api,
        surveyId: 's1',
        tiles: tiles ?? MapTiles.forToken(''),
        tileProvider: NoTiles(),
        heatRenderer: fakeHeat,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the map with floors, legend and attribution', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    expect(tester.takeException(), isNull);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.byType(OverlayImageLayer), findsOneWidget);
    expect(find.byType(PolygonLayer), findsNothing);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    // Opens on the floor with the most coverage (ground has two cells), drawn
    // as one picture from a 2 x 1 grid, not as polygons.
    expect(heatRequests, hasLength(1));
    final grid = heatRequests.single.grid;
    expect((grid.cols, grid.rows), (2, 1));
    expect(grid.values, [-50, -90]);
    // A cell the API is sure of is strong; one with none is faded.
    expect(grid.confidence, [1.0, 0.0]);
    // The picture is placed on the grid plus a blank cell all round, with
    // the SW corner of the floor's cells inside it.
    final overlay = overlayOf(tester);
    expect(overlay.bounds.south, closeTo(14.6 - 0.00001, 1e-9));
    expect(overlay.bounds.west, closeTo(121.0 - 0.00001, 1e-9));
    expect(overlay.bounds.north, closeTo(14.6 + 0.00002, 1e-9));
    expect(overlay.bounds.east, closeTo(121.0 + 0.00003, 1e-9));
    expect(overlay.opacity, 0.85);
    expect(find.text('Ground'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    // On a phone the legend starts collapsed, with a small bar and a toggle.
    expect(find.byKey(const ValueKey('legend-ramp-mini')), findsOneWidget);
    expect(find.byKey(const ValueKey('legend-ramp')), findsNothing);
    expect(find.text('Good ≥ -60 dBm'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('legend-toggle')));
    await tester.pumpAndSettle();
    // The surveyor's thresholds are in the legend.
    expect(find.text('Good ≥ -60 dBm'), findsOneWidget);
    expect(find.text('Dead < -75 dBm'), findsOneWidget);
    expect(find.byKey(const ValueKey('legend-faded')), findsOneWidget);
    expect(find.text('Faded = few readings'), findsOneWidget);
    // The legend is a gradient bar with dBm ticks.
    expect(find.byKey(const ValueKey('legend-ramp')), findsOneWidget);
    for (final tick in legendTicks) {
      expect(find.text('$tick'), findsOneWidget);
    }
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
    expect(drawnCells(), 1);
    expect(find.byKey(const ValueKey('heat-1')), findsOneWidget);
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
    expect(find.byType(OverlayImageLayer), findsNothing);
    expect(find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')), findsNothing);
    expect(find.byKey(const ValueKey('pin-S')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('layer-cells')));
    await tester.pumpAndSettle();
    expect(find.byType(OverlayImageLayer), findsOneWidget);
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

  testWidgets('access points are drawn by placement confidence (FR-25)', (
    tester,
  ) async {
    final routes = goodRoutes();
    routes['GET /api/surveys/s1/geojson'] = () => jsonResponse(
      collection([
        cell(121.0, 14.6, -50, 0, level: 'good'),
        ap(
          121.0001,
          14.6001,
          0,
          readings: 12,
          confidence: 0.9,
          lowConfidence: false,
          spreadM: 6.0,
        ),
        ap(
          121.0002,
          14.6001,
          0,
          bssid: 'aa:bb:cc:dd:ee:02',
          readings: 3,
          confidence: 0.1,
          lowConfidence: true,
          spreadM: 1.2,
        ),
      ]),
    );
    await pump(tester, routes);
    final sure = find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01'));
    final unsure = find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:02'));
    expect(
      find.descendant(
        of: sure,
        matching: find.byKey(const ValueKey('ap-solid')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: unsure,
        matching: find.byKey(const ValueKey('ap-hollow')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: unsure, matching: find.text('?')),
      findsOneWidget,
    );
    final ring = tester.widget<Opacity>(
      find.descendant(of: unsure, matching: find.byType(Opacity)),
    );
    expect(ring.opacity, 0.4);
    // The confident marker is the primary blue, not a signal colour.
    final disc = tester.widget<Container>(
      find.descendant(
        of: sure,
        matching: find.byKey(const ValueKey('ap-solid')),
      ),
    );
    expect((disc.decoration! as BoxDecoration).color, AppColors.primary);
    // Tap targets stay at least 48 dp.
    expect(tester.getSize(unsure).width, greaterThanOrEqualTo(kTarget));
    expect(tester.getSize(unsure).height, greaterThanOrEqualTo(kTarget));
    await tester.tap(unsure);
    await tester.pumpAndSettle();
    expect(
      find.text('Low confidence: 3 readings · spread 1.2 m · 10%'),
      findsOneWidget,
    );
  });

  testWidgets('the dead and weak zone layer can be switched on (FR-26)', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    expect(find.byKey(const ValueKey('zones-0')), findsNothing);
    final chip = find.byKey(const ValueKey('layer-zones'));
    expect(find.text('Dead & weak zones'), findsOneWidget);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(kTarget));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zones-0')), findsOneWidget);
    // Shown together with the heatmap, or instead of it.
    expect(find.byKey(const ValueKey('heat-0')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('layer-cells')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('heat-0')), findsNothing);
    expect(find.byKey(const ValueKey('zones-0')), findsOneWidget);
    // The legend gives both ranges from the survey's thresholds (-60 / -75).
    await tester.tap(find.byKey(const ValueKey('legend-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Weak: -75 to -60 dBm'), findsOneWidget);
    expect(find.text('Dead: below -75 dBm'), findsOneWidget);
    expect(find.byKey(const ValueKey('zone-swatch-dead')), findsOneWidget);
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('zones-0')), findsNothing);
    expect(find.text('Weak: -75 to -60 dBm'), findsNothing);
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

  group('network picker', () {
    Future<void> choose(WidgetTester tester, String text) async {
      await tester.tap(find.byKey(const ValueKey('network-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(text).last);
      await tester.pumpAndSettle();
    }

    testWidgets('lists All networks and each BSSID once, with counts', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      expect(find.text('All networks (strongest signal)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('network-picker')));
      await tester.pumpAndSettle();
      expect(find.text('Lab · aa:bb:cc:dd:ee:01 (40)'), findsOneWidget);
      expect(
        find.text('(hidden network) · aa:bb:cc:dd:ee:02 (12)'),
        findsOneWidget,
      );
      expect(find.textContaining('Lab-guest'), findsNothing);
    });

    testWidgets('choosing a network loads only that network\'s layers', (
      tester,
    ) async {
      final calls = await pump(tester, goodRoutes());
      expect(drawnCells(), 2);
      await choose(tester, 'Lab · aa:bb');
      expect(
        calls,
        contains('GET /api/surveys/s1/geojson?bssid=aa:bb:cc:dd:ee:01'),
      );
      expect(drawnCells(), 1);
      // The walk, the floors and the access point stay.
      expect(find.byKey(const ValueKey('pin-S')), findsOneWidget);
      expect(find.text('Ground'), findsOneWidget);
      expect(find.text('First'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ap-aa:bb:cc:dd:ee:01')),
        findsOneWidget,
      );
      // The trail was not loaded again.
      expect(calls.where((c) => c.endsWith('/trail')), hasLength(1));
    });

    testWidgets('going back to all networks restores the strongest signal', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      await choose(tester, 'Lab · aa:bb');
      await choose(tester, 'All networks');
      expect(drawnCells(), 2);
    });

    testWidgets('a network with nothing on the floor says so', (tester) async {
      await pump(tester, goodRoutes());
      await choose(tester, 'aa:bb:cc:dd:ee:02');
      expect(find.byType(OverlayImageLayer), findsNothing);
      expect(
        find.text('No readings of this network on this floor.'),
        findsOneWidget,
      );
      // The floors and the walk are still there.
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('First'), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-S')), findsOneWidget);
    });

    testWidgets('a failed load keeps the network and says why', (tester) async {
      final routes = goodRoutes();
      routes['GET /api/surveys/s1/geojson?bssid=aa:bb:cc:dd:ee:01'] = () =>
          jsonResponse({'detail': 'Boom'}, 500);
      await pump(tester, routes);
      await choose(tester, 'Lab · aa:bb');
      expect(find.textContaining('Boom'), findsOneWidget);
      expect(find.text('All networks (strongest signal)'), findsOneWidget);
      expect(drawnCells(), 2);
      expect(find.byType(OverlayImageLayer), findsOneWidget);
    });

    testWidgets('offline keeps the network and says so', (tester) async {
      var offline = false;
      final api = apiFor((req) async {
        if (offline && req.url.queryParameters.containsKey('bssid')) {
          throw http.ClientException('down');
        }
        final r = goodRoutes()['${req.method} ${req.url.path}'];
        return r == null ? http.Response('{}', 404) : r();
      });
      await pumpWith(tester, api);
      offline = true;
      await choose(tester, 'Lab · aa:bb');
      expect(find.textContaining('offline'), findsOneWidget);
    });

    testWidgets('without the network list the map still works', (tester) async {
      final routes = goodRoutes();
      routes.remove('GET /api/surveys/s1/networks');
      await pump(tester, routes);
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.text('All networks (strongest signal)'), findsOneWidget);
    });
  });

  group('display settings', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('display-settings')));
      await tester.pumpAndSettle();
    }

    testWidgets('the sheet has opacity, min RSSI and contour controls', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      await openSheet(tester);
      expect(find.byKey(const ValueKey('heat-opacity')), findsOneWidget);
      expect(find.byKey(const ValueKey('heat-min-rssi')), findsOneWidget);
      expect(find.byKey(const ValueKey('heat-contours')), findsOneWidget);
      expect(find.text('Opacity 85%'), findsOneWidget);
      expect(find.text('Min RSSI -100 dBm'), findsOneWidget);
    });

    testWidgets('opacity changes the overlay without redrawing it', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      await openSheet(tester);
      final slider = tester.getRect(find.byKey(const ValueKey('heat-opacity')));
      // Drag the thumb to the far left: the lowest opacity, 10%.
      await tester.dragFrom(
        Offset(slider.left + slider.width * 0.75, slider.center.dy),
        Offset(-slider.width * 2, 0),
      );
      await tester.pumpAndSettle();
      expect(overlayOf(tester).opacity, closeTo(0.1, 1e-9));
      expect(find.text('Opacity 10%'), findsOneWidget);
      expect(heatRequests, hasLength(1), reason: 'only the widget changed');
    });

    testWidgets('min RSSI draws the picture again with the new cut-off', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      await openSheet(tester);
      expect(heatRequests.last.minRssi, -100);
      final slider = tester.getRect(
        find.byKey(const ValueKey('heat-min-rssi')),
      );
      // To the far right: -30 dBm, the strongest end.
      await tester.dragFrom(
        Offset(slider.left + slider.width * 0.25, slider.center.dy),
        Offset(slider.width * 2, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('Min RSSI -30 dBm'), findsOneWidget);
      expect(heatRequests, hasLength(2));
      expect(heatRequests.last.minRssi, -30);
    });

    testWidgets('contour lines switch off and back from the cache', (
      tester,
    ) async {
      await pump(tester, goodRoutes());
      await openSheet(tester);
      expect(heatRequests.last.contours, isTrue);
      await tester.tap(find.byKey(const ValueKey('heat-contours')));
      await tester.pumpAndSettle();
      expect(heatRequests, hasLength(2));
      expect(heatRequests.last.contours, isFalse);
      // Back on: the earlier picture is reused, nothing is drawn again.
      await tester.tap(find.byKey(const ValueKey('heat-contours')));
      await tester.pumpAndSettle();
      expect(heatRequests, hasLength(2));
      expect(find.byType(OverlayImageLayer), findsOneWidget);
    });
  });

  testWidgets('tapping the map shows the nearest cell\'s value', (
    tester,
  ) async {
    await pump(tester, goodRoutes());
    expect(find.byKey(const ValueKey('cell-info')), findsNothing);
    // Away from the controls, pins and legend. The map waits a moment to
    // tell a tap from a double tap.
    await tester.tapAt(const Offset(60, 380));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cell-info')), findsOneWidget);
    // Both cells have a value; the panel names it, its level and that it is
    // the nearest cell (the picture itself is smooth).
    expect(
      find.textContaining(
        RegExp(r'^-(50|90) dBm · (Good|Dead) · nearest cell$'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the 2D / 3D switch is offered when given', (tester) async {
    BuildContext? got;
    await pump(tester, goodRoutes(), onOpen3d: (c) => got = c);
    await tester.tap(find.text('3D'));
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

  group('layout and style', () {
    setUp(() => MapStylePreference.current = MapStyle.satellite);
    tearDown(() => MapStylePreference.current = MapStyle.satellite);

    ApiClient goodApi() => apiFor((req) async {
      final r = goodRoutes()['${req.method} ${req.url.path}'];
      return r == null ? http.Response('{}', 404) : r();
    });

    String tileUrl(WidgetTester tester) =>
        tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate!;

    testWidgets('the legend is collapsed on a phone and can be opened', (
      tester,
    ) async {
      await pumpWith(tester, goodApi(), width: 800); // 400 dp
      expect(find.byKey(const ValueKey('legend-ramp')), findsNothing);
      expect(find.byKey(const ValueKey('legend-ramp-mini')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('legend-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('legend-ramp')), findsOneWidget);
      expect(find.byKey(const ValueKey('legend-ramp-mini')), findsNothing);
      // And back.
      await tester.tap(find.byKey(const ValueKey('legend-toggle')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('legend-ramp')), findsNothing);
    });

    testWidgets('the legend starts open on a tablet', (tester) async {
      await pumpWith(tester, goodApi(), width: 1600); // 800 dp
      expect(find.byKey(const ValueKey('legend-ramp')), findsOneWidget);
      expect(find.byKey(const ValueKey('legend-ramp-mini')), findsNothing);
    });

    testWidgets('the controls sit in two cards that do not overlap', (
      tester,
    ) async {
      await pumpWith(tester, goodApi(), width: 720); // 360 dp
      final top = tester.getRect(find.byKey(const ValueKey('top-panel')));
      final bottom = tester.getRect(find.byKey(const ValueKey('toolbar')));
      final legend = tester.getRect(find.byKey(const ValueKey('legend')));
      expect(top.overlaps(bottom), isFalse);
      expect(top.overlaps(legend), isFalse);
      expect(bottom.overlaps(legend), isFalse);
      // Together they leave a good part of the map free (the test font is much
      // wider than a real one, so the toolbar wraps here).
      final map = tester.getRect(find.byType(FlutterMap));
      final taken = top.height + bottom.height + legend.height;
      expect(taken, lessThan(map.height * 0.6));
      // Everything fits across a 360 dp phone.
      for (final r in [top, bottom, legend]) {
        expect(r.left, greaterThanOrEqualTo(0));
        expect(r.right, lessThanOrEqualTo(360));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('with a token the style can be changed', (tester) async {
      await pumpWith(tester, goodApi(), tiles: MapTiles.forToken('pk.test'));
      expect(tileUrl(tester), contains('/mapbox/satellite-streets-v12/'));

      await tester.tap(find.byKey(const ValueKey('map-style')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('style-note')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('style-streetsDark')));
      await tester.pumpAndSettle();
      expect(tileUrl(tester), contains('/mapbox/dark-v11/'));
      // Still the same token.
      expect(
        tester.widget<TileLayer>(find.byType(TileLayer)).additionalOptions,
        {'accessToken': 'pk.test'},
      );

      await tester.tap(find.byKey(const ValueKey('map-style')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('style-streetsLight')));
      await tester.pumpAndSettle();
      expect(tileUrl(tester), contains('/mapbox/light-v11/'));
      // The choice is kept for the next map in this session.
      expect(MapStylePreference.current, MapStyle.streetsLight);
      await pumpWith(tester, goodApi(), tiles: MapTiles.forToken('pk.test'));
      expect(tileUrl(tester), contains('/mapbox/light-v11/'));
    });

    testWidgets('without a token the picker is off and says why', (
      tester,
    ) async {
      await pumpWith(tester, goodApi());
      expect(tileUrl(tester), contains('tile.openstreetmap.org'));
      await tester.tap(find.byKey(const ValueKey('map-style')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('style-note')), findsOneWidget);
      expect(find.textContaining('Mapbox token'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('style-streetsDark')));
      await tester.pumpAndSettle();
      // Nothing changed and the sheet is still up.
      expect(MapStylePreference.current, MapStyle.satellite);
      expect(tileUrl(tester), contains('tile.openstreetmap.org'));
      expect(find.byKey(const ValueKey('style-note')), findsOneWidget);
    });
  });

  testWidgets('the app bar opens router coverage mode (FR-27)', (tester) async {
    final routes = goodRoutes();
    routes['GET /api/surveys/s1/routers'] = () =>
        jsonResponse({'floors': <Object>[]});
    final calls = await pump(tester, routes);
    await tester.tap(find.byKey(const ValueKey('open-routers')));
    await tester.pumpAndSettle();
    expect(calls, contains('GET /api/surveys/s1/routers'));
    expect(find.text('Router coverage'), findsOneWidget);
    expect(find.text('No routers'), findsOneWidget);
  });
}
