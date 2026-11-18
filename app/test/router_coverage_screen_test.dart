import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/map_tiles.dart';
import 'package:signalscape_mobile/screens/router_coverage_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'map_screen_test.dart' show NoTiles;
import 'router_data_test.dart'
    show coverageJson, extendedRouterJson, staffNetwork;
import 'support.dart';

Future<List<String>> pumpRouters(
  WidgetTester tester,
  http.Response Function() response,
) async {
  final calls = <String>[];
  final api = apiFor((req) async {
    calls.add('${req.method} ${req.url.path}');
    if (req.url.path == '/api/surveys/s1/routers') return response();
    return http.Response('{"detail":"Not found"}', 404);
  });
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: RouterCoverageScreen(
        key: UniqueKey(),
        api: api,
        surveyId: 's1',
        tiles: MapTiles.forToken(''),
        tileProvider: NoTiles(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  testWidgets('opens on an extended network and draws its heatmap, not '
      'per-router footprints', (tester) async {
    final calls = await pumpRouters(tester, () => jsonResponse(coverageJson()));
    expect(calls, ['GET /api/surveys/s1/routers']);
    expect(find.text('Router coverage'), findsOneWidget);
    expect(find.byKey(const ValueKey('network-name')), findsOneWidget);
    expect(find.text('staff'), findsWidgets);
    expect(
      find.text(
        'staff · 2 routers in this network · 3 in the survey, from 4 BSSIDs',
      ),
      findsOneWidget,
    );
    expect(find.text('Router 1'), findsOneWidget);
    expect(find.text('Router 2'), findsOneWidget);
    expect(find.text('Likely main · strongest -35 dBm'), findsOneWidget);
    expect(find.text('Extender · strongest -50 dBm'), findsOneWidget);
    expect(find.byKey(const ValueKey('network-heat')), findsOneWidget);
    expect(find.byKey(const ValueKey('footprint-1')), findsNothing);
    expect(find.byKey(const ValueKey('footprint-2')), findsNothing);
    // Rows and markers keep 48 dp targets.
    expect(
      tester.getSize(find.byKey(const ValueKey('router-tile-1'))).height,
      greaterThanOrEqualTo(kTarget),
    );
    final marker = find.byKey(const ValueKey('router-2'));
    expect(tester.getSize(marker).width, greaterThanOrEqualTo(kTarget));
    expect(
      find.descendant(
        of: marker,
        matching: find.byKey(const ValueKey('router-hollow')),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('router-1')),
        matching: find.byKey(const ValueKey('router-solid')),
      ),
      findsOneWidget,
    );
    final disc = tester.widget<Container>(
      find.descendant(
        of: find.byKey(const ValueKey('router-1')),
        matching: find.byKey(const ValueKey('router-solid')),
      ),
    );
    // Router 1 is the primary blue, not a signal colour.
    expect((disc.decoration! as BoxDecoration).color, AppColors.primary);
    await tester.tap(find.byKey(const ValueKey('router-tile-1')));
    await tester.pumpAndSettle();
    expect(find.text('Likely main (estimate)'), findsOneWidget);
    expect(find.byKey(const ValueKey('main-heuristic')), findsOneWidget);
    expect(find.textContaining('strongest reading'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(marker);
    await tester.pumpAndSettle();
    expect(find.text('Extender'), findsWidgets);
    expect(find.text('Low confidence placement'), findsOneWidget);
    expect(find.textContaining('aa:bb:cc:dd:ee:20'), findsOneWidget);
  });

  testWidgets('traces the chain and shows the gap between routers (FR-29)', (
    tester,
  ) async {
    await pumpRouters(tester, () => jsonResponse(coverageJson()));
    await tester.scrollUntilVisible(
      find.text('Dead: below -75 dBm'),
      100,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('router-list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('Links and gaps'), findsOneWidget);
    expect(
      find.textContaining(
        'Router 1 → Router 2 · 10 m · dead gap 4 m (weakest -91 dBm)',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('6 m² weak or dead between them'),
      findsOneWidget,
    );
    expect(find.text('Weak: -75 to -60 dBm'), findsOneWidget);
    expect(find.text('Dead: below -75 dBm'), findsOneWidget);
    expect(find.byKey(const ValueKey('gaps-0')), findsOneWidget);
    final links = tester.widget<PolylineLayer>(
      find.byKey(const ValueKey('chain-links')),
    );
    expect(links.polylines.single.color, AppColors.dead);
    await tester.ensureVisible(find.byKey(const ValueKey('show-gaps')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('show-gaps'))).height,
      greaterThanOrEqualTo(kTarget),
    );
    await tester.tap(find.byKey(const ValueKey('show-gaps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gaps-0')), findsNothing);
    expect(find.byKey(const ValueKey('network-heat')), findsOneWidget);
    expect(find.byKey(const ValueKey('chain-links')), findsOneWidget);
  });

  testWidgets('lists an undetermined router without a pin', (tester) async {
    await pumpRouters(
      tester,
      () => jsonResponse(
        coverageJson(
          extendedNetworks: [
            staffNetwork(
              routers: [
                extendedRouterJson(1, role: 'likely_main', rssi: -35),
                extendedRouterJson(2, determined: false, rssi: -78),
              ],
              links: [],
              includeGaps: false,
            ),
          ],
        ),
      ),
    );
    expect(find.textContaining('Position not determined'), findsOneWidget);
    expect(find.byKey(const ValueKey('router-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('router-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('router-tile-2')));
    await tester.pumpAndSettle();
    expect(find.text('Position not determined'), findsWidgets);
    expect(find.text('Likely main (estimate)'), findsNothing);
  });

  testWidgets('switches between extended networks', (tester) async {
    final guest = staffNetwork();
    guest['ssid'] = 'guest';
    guest['likely_main'] = 'r1';
    final staff = staffNetwork();
    await pumpRouters(
      tester,
      () => jsonResponse(coverageJson(extendedNetworks: [staff, guest])),
    );
    expect(find.byKey(const ValueKey('network-picker')), findsOneWidget);
    expect(find.text('staff'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('network-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('guest').last);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('guest · 2 routers in this network'),
      findsOneWidget,
    );
  });

  testWidgets('not processed, empty, no extended networks and offline', (
    tester,
  ) async {
    await pumpRouters(
      tester,
      () => jsonResponse({
        'detail': 'This survey has not been processed yet',
      }, 409),
    );
    expect(find.text('Not processed yet'), findsOneWidget);
    await pumpRouters(
      tester,
      () => jsonResponse({'floors': <Object>[], 'thresholds': null}),
    );
    expect(find.text('No routers'), findsOneWidget);
    await pumpRouters(
      tester,
      () => jsonResponse(coverageJson(extendedNetworks: [])),
    );
    expect(find.text('No extended networks'), findsOneWidget);
    await pumpRouters(tester, () => throw http.ClientException('offline'));
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
