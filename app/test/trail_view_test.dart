import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/levels.dart';
import 'package:signalscape_mobile/core/preview.dart';
import 'package:signalscape_mobile/theme.dart';
import 'package:signalscape_mobile/widgets/trail_view.dart';

PreviewGrid grid() => PreviewGrid(
  floorId: 'f1',
  cellM: 2,
  cols: 3,
  rows: 2,
  x0: -2,
  y0: -2,
  values: const [-50, -75, null, -90, null, -60],
  computedAt: DateTime(2026, 11, 16),
);

Future<void> pump(
  WidgetTester tester, {
  PreviewGrid? preview,
  List<TrailPoint> points = const [],
  List<PathPoint> path = const [],
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(),
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 300,
        child: TrailView(
          points: points,
          path: path,
          x: 1,
          y: 1,
          heading: 0.5,
          preview: preview,
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('draws with no trail and no heatmap', (tester) async {
    await pump(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draws the preview heatmap under the trail', (tester) async {
    await pump(
      tester,
      preview: grid(),
      points: const [
        TrailPoint(0, 0, SignalLevel.good),
        TrailPoint(3, 2, SignalLevel.dead),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(
      find.bySemanticsLabel('Live trail with 2 scan points'),
      findsOneWidget,
    );
  });

  testWidgets('a grid far from the trail still fits on screen', (tester) async {
    final far = PreviewGrid(
      floorId: 'f1',
      cellM: 1,
      cols: 2,
      rows: 2,
      x0: 500,
      y0: 500,
      values: const [-50, -50, -50, -50],
      computedAt: DateTime(2026, 11, 16),
    );
    await pump(tester, preview: far);
    expect(tester.takeException(), isNull);
  });

  testWidgets('draws the walk with a start marker, with or without scans', (
    tester,
  ) async {
    final walk = [
      for (var i = 0; i < 40; i++) PathPoint(i * 0.7, i * 0.3, i.toDouble()),
    ];
    await pump(tester, path: walk);
    expect(tester.takeException(), isNull);
    await pump(
      tester,
      preview: grid(),
      path: walk,
      points: const [TrailPoint(1.4, 0.6, SignalLevel.fair, 2)],
    );
    expect(tester.takeException(), isNull);
    // A single breadcrumb is only the start marker.
    await pump(tester, path: const [PathPoint(0, 0)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a far heatmap does not move the view off the walk', (
    tester,
  ) async {
    final far = PreviewGrid(
      floorId: 'f1',
      cellM: 1,
      cols: 3,
      rows: 3,
      x0: -40,
      y0: -40,
      values: List.filled(9, -55),
      computedAt: DateTime(2026, 11, 16),
    );
    await pump(
      tester,
      preview: far,
      path: const [PathPoint(0, 0), PathPoint(2, 1, 3)],
    );
    expect(tester.takeException(), isNull);
  });
}
