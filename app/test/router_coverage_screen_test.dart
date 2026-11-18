import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/map_tiles.dart';
import 'package:signalscape_mobile/screens/router_coverage_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'map_screen_test.dart' show NoTiles;
import 'router_data_test.dart' show coverageJson;
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
  testWidgets('lists routers with their networks and draws the selected '
      'footprints (FR-27, FR-28)', (tester) async {
    final calls = await pumpRouters(tester, () => jsonResponse(coverageJson()));
    expect(calls, ['GET /api/surveys/s1/routers']);
    expect(find.text('Router coverage'), findsOneWidget);
    expect(
      find.text('2 routers on this floor · 3 in the survey, from 4 BSSIDs'),
      findsOneWidget,
    );
    expect(find.text('Router 1: guest, staff'), findsOneWidget);
    expect(find.text('Router 2: staff'), findsOneWidget);
    // The strongest router is shown first; the second one is ticked on.
    expect(find.byKey(const ValueKey('footprint-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('footprint-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('router-tile-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('footprint-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('router-tile-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('footprint-1')), findsNothing);
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
    await tester.tap(marker);
    await tester.pumpAndSettle();
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
    expect(find.text('Extended networks'), findsOneWidget);
    expect(find.text('staff: Router 1, Router 2'), findsOneWidget);
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
    // Tapping the chain shows every router of it.
    await tester.tap(find.byKey(const ValueKey('chain-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('footprint-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('footprint-2')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('show-gaps')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('show-gaps'))).height,
      greaterThanOrEqualTo(kTarget),
    );
    await tester.tap(find.byKey(const ValueKey('show-gaps')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('gaps-0')), findsNothing);
  });

  testWidgets('switches floors', (tester) async {
    await pumpRouters(tester, () => jsonResponse(coverageJson()));
    await tester.tap(find.byKey(const ValueKey('router-floor-1')));
    await tester.pumpAndSettle();
    expect(find.text('Router 3: lab'), findsOneWidget);
    expect(find.byKey(const ValueKey('footprint-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('no-chains')), findsOneWidget);
  });

  testWidgets('not processed, empty and offline', (tester) async {
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
    await pumpRouters(tester, () => throw http.ClientException('offline'));
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}
