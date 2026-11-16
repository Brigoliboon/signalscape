import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:signalscape_mobile/core/export_share.dart';
import 'package:signalscape_mobile/data/api_client.dart';
import 'package:signalscape_mobile/data/summary_models.dart';
import 'package:signalscape_mobile/screens/survey_summary_screen.dart';
import 'package:signalscape_mobile/theme.dart';

import 'map_screen_test.dart' as map_tests;
import 'support.dart';

const _id = '1a2b3c4d-0000-4000-8000-000000000000';

Map<String, dynamic> floorSummary(
  int level,
  String label, {
  int raw = 100,
  int cleaned = 80,
  double area = 200,
  double good = 50,
  double fair = 30,
  double dead = 20,
  int aps = 2,
}) => {
  'floor_id': 'f$level',
  'floor_level': level,
  'floor_label': label,
  'floor_height_m': 3.0,
  'raw_reading_count': raw,
  'cleaned_reading_count': cleaned,
  'area_covered_m2': area,
  'good_pct': good,
  'fair_pct': fair,
  'dead_pct': dead,
  'thresholds': {'good_dbm': -67, 'dead_dbm': -80},
  'access_point_count': aps,
};

Map<String, dynamic> summaryJson([List<Map<String, dynamic>>? floors]) => {
  'survey_id': _id,
  'status': 'processed',
  'processed_at': '2026-11-16T06:55:00Z',
  'floors':
      floors ??
      [
        floorSummary(
          1,
          'First',
          raw: 50,
          cleaned: 40,
          area: 100,
          good: 100,
          fair: 0,
          dead: 0,
          aps: 1,
        ),
        floorSummary(
          0,
          'Ground',
          raw: 100,
          cleaned: 80,
          area: 300,
          good: 20,
          fair: 40,
          dead: 40,
        ),
      ],
};

class Shared {
  String? name;
  String? mime;
  List<int>? bytes;
  int count = 0;
}

void main() {
  late List<http.Request> calls;
  late Shared shared;

  Future<void> mount(
    WidgetTester tester,
    Future<http.Response> Function(http.Request) handler, {
    bool canProcess = false,
    bool shareFails = false,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    calls = [];
    shared = Shared();
    final api = apiFor((req) async {
      calls.add(req);
      return handler(req);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SurveySummaryScreen(
          api: api,
          surveyId: _id,
          canProcess: canProcess,
          shareFile:
              ({required name, required mimeType, required bytes}) async {
                if (shareFails) throw StateError('no share sheet');
                shared
                  ..name = name
                  ..mime = mimeType
                  ..bytes = bytes
                  ..count += 1;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<http.Response> ok(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/summary')) return jsonResponse(summaryJson());
    if (path.endsWith('/export.csv')) {
      return http.Response(
        'scanned_at,bssid\n2026-11-16T06:00:00Z,aa:bb:cc:dd:ee:01\n',
        200,
        headers: {'content-type': 'text/csv'},
      );
    }
    if (path.endsWith('/geojson')) {
      return jsonResponse({'type': 'FeatureCollection', 'features': []});
    }
    return jsonResponse({'detail': 'Not found'}, 404);
  }

  testWidgets('shows the totals and each floor, lowest floor first', (
    tester,
  ) async {
    await mount(tester, ok);
    final total = find.byKey(const ValueKey('summary-total'));
    Finder inTotal(String t) =>
        find.descendant(of: total, matching: find.text(t));
    expect(inTotal('All floors'), findsOneWidget);
    expect(inTotal('2'), findsOneWidget); // floors and... access points differ
    expect(inTotal('120 of 150'), findsOneWidget);
    expect(inTotal('400 m²'), findsOneWidget);
    expect(inTotal('3'), findsOneWidget); // access points
    // Area-weighted: (100*100 + 20*300) / 400 = 40 % good, 30 % fair, 30 % dead.
    expect(inTotal('Good 40.0%'), findsOneWidget);
    expect(inTotal('Fair 30.0%'), findsOneWidget);
    expect(inTotal('Dead 30.0%'), findsOneWidget);
    expect(find.byKey(const ValueKey('floor-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('floor-1')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('floor-0'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const ValueKey('floor-1'))).dy),
    );
    expect(find.text('Ground'), findsOneWidget);
    expect(find.text('80 of 100'), findsOneWidget);
    expect(find.text('Dead 40.0%'), findsOneWidget);
    expect(find.textContaining('Processed 20'), findsOneWidget);
  });

  testWidgets('a floor with no readings says so', (tester) async {
    await mount(tester, (req) async {
      return jsonResponse(
        summaryJson([
          floorSummary(
            0,
            'Ground',
            raw: 0,
            cleaned: 0,
            area: 0,
            good: 0,
            fair: 0,
            dead: 0,
            aps: 0,
          ),
        ]),
      );
    });
    expect(find.textContaining('No coverage to describe'), findsNWidgets(2));
  });

  testWidgets('large areas are shown in hectares', (tester) async {
    await mount(tester, (req) async {
      return jsonResponse(
        summaryJson([floorSummary(0, 'Ground', area: 25000)]),
      );
    });
    expect(find.text('2.50 ha'), findsWidgets);
  });

  group('not processed', () {
    Future<http.Response> notProcessed(http.Request req) async {
      if (req.url.path.endsWith('/process')) {
        return jsonResponse({'survey_id': _id, 'status': 'processed'});
      }
      return jsonResponse({'detail': 'Process this survey first'}, 409);
    }

    testWidgets('a viewer is told to ask the surveyor', (tester) async {
      await mount(tester, notProcessed);
      expect(find.text('Not processed yet'), findsOneWidget);
      expect(find.textContaining('Ask the surveyor'), findsOneWidget);
      expect(find.byKey(const ValueKey('process-now')), findsNothing);
    });

    testWidgets('a surveyor can process it and then sees the summary', (
      tester,
    ) async {
      var processed = false;
      await mount(tester, (req) async {
        if (req.url.path.endsWith('/process')) {
          processed = true;
          return jsonResponse({'survey_id': _id, 'status': 'processed'});
        }
        return processed ? ok(req) : notProcessed(req);
      }, canProcess: true);
      await tester.tap(find.byKey(const ValueKey('process-now')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('summary-total')), findsOneWidget);
    });

    testWidgets('a processing error is shown', (tester) async {
      await mount(tester, (req) async {
        if (req.url.path.endsWith('/process')) {
          return jsonResponse({'detail': 'No readings'}, 422);
        }
        return notProcessed(req);
      }, canProcess: true);
      await tester.tap(find.byKey(const ValueKey('process-now')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not process the survey: No readings'),
        findsOneWidget,
      );
      expect(find.text('Not processed yet'), findsOneWidget);
    });
  });

  testWidgets('a failure shows the reason and can be retried', (tester) async {
    var fail = true;
    await mount(tester, (req) async {
      if (fail) return jsonResponse({'detail': 'Boom'}, 500);
      return ok(req);
    });
    expect(find.text("Couldn't load the summary"), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('summary-total')), findsOneWidget);
  });

  testWidgets('offline is explained', (tester) async {
    await mount(tester, (req) async => throw http.ClientException('down'));
    expect(find.text("You're offline"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  group('export', () {
    testWidgets('CSV is fetched and handed to the share sheet', (tester) async {
      await mount(tester, ok);
      await tester.tap(find.byKey(const ValueKey('export-csv')));
      await tester.pumpAndSettle();
      expect(
        calls.any((c) => c.url.path == '/api/surveys/$_id/export.csv'),
        isTrue,
      );
      expect(shared.name, 'signalscape-survey-1a2b3c4d.csv');
      expect(shared.mime, 'text/csv');
      expect(utf8.decode(shared.bytes!), startsWith('scanned_at,bssid'));
      expect(shared.count, 1);
    });

    testWidgets('GeoJSON is fetched and handed to the share sheet', (
      tester,
    ) async {
      await mount(tester, ok);
      await tester.tap(find.byKey(const ValueKey('export-geojson')));
      await tester.pumpAndSettle();
      expect(shared.name, 'signalscape-survey-1a2b3c4d.geojson');
      expect(shared.mime, 'application/geo+json');
      expect(
        jsonDecode(utf8.decode(shared.bytes!)),
        containsPair('type', 'FeatureCollection'),
      );
    });

    testWidgets('a server error is shown and nothing is shared', (
      tester,
    ) async {
      await mount(tester, (req) async {
        if (req.url.path.endsWith('/export.csv')) {
          return jsonResponse({'detail': 'Not found'}, 404);
        }
        return ok(req);
      });
      await tester.tap(find.byKey(const ValueKey('export-csv')));
      await tester.pumpAndSettle();
      expect(find.text('Could not export: Not found'), findsOneWidget);
      expect(shared.count, 0);
    });

    testWidgets('offline during export is explained', (tester) async {
      await mount(tester, (req) async {
        if (req.url.path.endsWith('/export.csv')) {
          throw http.ClientException('down');
        }
        return ok(req);
      });
      await tester.tap(find.byKey(const ValueKey('export-csv')));
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
    });

    testWidgets('a phone without a share sheet gets a message', (tester) async {
      await mount(tester, ok, shareFails: true);
      await tester.tap(find.byKey(const ValueKey('export-csv')));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not open the share sheet on this phone.'),
        findsOneWidget,
      );
      // The buttons are usable again.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('export-csv')))
            .onPressed,
        isNotNull,
      );
    });
  });

  testWidgets('the 2D map opens the summary', (tester) async {
    final routes = map_tests.goodRoutes();
    routes['GET /api/surveys/s1/summary'] = () => jsonResponse(summaryJson());
    await map_tests.pump(tester, routes);
    await tester.tap(find.byKey(const ValueKey('open-summary')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(SurveySummaryScreen), findsOneWidget);
  });

  test('summary models and file names', () {
    final d = SurveySummaryData.fromJson(summaryJson());
    expect(d.floors.map((f) => f.level), [0, 1]);
    expect(d.cleanedReadings, 120);
    expect(d.rawReadings, 150);
    expect(d.accessPoints, 3);
    expect(d.areaM2, 400);
    expect(d.goodPct, closeTo(40, 1e-9));
    final empty = SurveySummaryData.fromJson(summaryJson([]));
    expect(empty.goodPct, 0);
    expect(empty.areaM2, 0);
    expect(exportFileName(_id, 'csv'), 'signalscape-survey-1a2b3c4d.csv');
    expect(exportFileName('abc', 'csv'), 'signalscape-survey-abc.csv');
  });

  test('exportCsv reports a refused or unreachable server', () async {
    final denied = apiFor((_) async => jsonResponse({'detail': 'No'}, 404));
    await expectLater(
      denied.exportCsv(_id),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
    var unauthorized = 0;
    final expired = apiFor((_) async => jsonResponse({'detail': 'x'}, 401))
      ..token = 't'
      ..onUnauthorized = () => unauthorized++;
    await expectLater(expired.exportCsv(_id), throwsA(isA<ApiException>()));
    expect(unauthorized, 1);
    final down = apiFor((_) async => throw http.ClientException('x'));
    await expectLater(
      down.exportCsv(_id),
      throwsA(isA<ApiException>().having((e) => e.isNetwork, 'network', true)),
    );
  });
}
