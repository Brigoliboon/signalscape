import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/levels.dart';
import '../core/preview.dart';
import '../theme.dart';

class TrailPoint {
  const TrailPoint(
    this.x,
    this.y,
    this.level, [
    this.progress = 0,
    this.floorId = '',
  ]);

  final double x;
  final double y;
  final SignalLevel level;

  /// Steps walked when the point was taken, for drift correction.
  final double progress;

  /// The floor the scan was taken on.
  final String floorId;
}

/// One breadcrumb of the walk, taken at every step, so the path is drawn
/// continuously even when Wi-Fi scans are rare.
class PathPoint {
  const PathPoint(this.x, this.y, [this.progress = 0, this.floorId = '']);

  final double x;
  final double y;
  final double progress;
  final String floorId;
}

/// The walk so far: a solid line through every step, a dot per Wi-Fi scan
/// coloured by signal level, and a marker where the walk started, over the
/// live preview heatmap when there is one. The view fits the walk, not the
/// heatmap, and re-fits as the walk grows; north is up.
class TrailView extends StatelessWidget {
  const TrailView({
    super.key,
    required this.points,
    this.path = const [],
    required this.x,
    required this.y,
    required this.heading,
    this.preview,
    this.thresholds = const Thresholds(),
  });

  final List<TrailPoint> points;

  /// Breadcrumbs of the walk, oldest first; the first is the start.
  final List<PathPoint> path;

  /// Heatmap drawn under the trail, in the same metre frame.
  final PreviewGrid? preview;
  final Thresholds thresholds;
  final double x;
  final double y;

  /// Radians clockwise from north, or null if unknown.
  final double? heading;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Live trail with ${points.length} scan points',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: CustomPaint(
          painter: _TrailPainter(
            points,
            path,
            x,
            y,
            heading,
            preview,
            thresholds,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  _TrailPainter(
    this.points,
    this.path,
    this.x,
    this.y,
    this.heading,
    this.preview,
    this.thresholds,
  );

  final PreviewGrid? preview;
  final Thresholds thresholds;
  final List<TrailPoint> points;
  final List<PathPoint> path;
  final double x;
  final double y;
  final double? heading;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = AppColors.surface);
    // Fit everything with a margin, at least a 20 m span so it starts calm.
    var minX = x, maxX = x, minY = y, maxY = y;
    for (final p in points) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    for (final p in path) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    // The heatmap is not part of the fit: it is only drawn where it shows.
    final g = preview;
    final span = math.max(20.0, math.max(maxX - minX, maxY - minY));
    const pad = 28.0;
    final scale = (math.min(size.width, size.height) - 2 * pad) / span;
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    Offset at(double px, double py) => Offset(
      size.width / 2 + (px - cx) * scale,
      size.height / 2 - (py - cy) * scale,
    );

    // The preview heatmap, under everything else.
    if (g != null) {
      final cell = g.cellM * scale;
      final paint = Paint();
      for (var row = 0; row < g.rows; row++) {
        for (var col = 0; col < g.cols; col++) {
          final v = g.at(col, row);
          if (v == null) continue;
          final tl = at(g.x0 + col * g.cellM, g.y0 + (row + 1) * g.cellM);
          if (tl.dx > size.width ||
              tl.dy > size.height ||
              tl.dx + cell < 0 ||
              tl.dy + cell < 0) {
            continue;
          }
          // Faded where few readings back the cell.
          paint.color = levelColor(levelFor(v.round(), thresholds)).withValues(
            alpha: confidenceAlpha(g.confidenceAt(col, row), full: 0.55),
          );
          canvas.drawRect(
            Rect.fromLTWH(tl.dx, tl.dy, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }

    // A 5 m grid.
    final grid = Paint()
      ..color = AppColors.outline.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    final step = 5 * scale;
    final origin = at(0, 0);
    for (var gx = origin.dx % step; gx < size.width; gx += step) {
      canvas.drawLine(Offset(gx, 0), Offset(gx, size.height), grid);
    }
    for (var gy = origin.dy % step; gy < size.height; gy += step) {
      canvas.drawLine(Offset(0, gy), Offset(size.width, gy), grid);
    }

    // The walk: a dark casing under a bright line, so it stands out over the
    // heatmap whatever the colours below it.
    if (path.length > 1) {
      final line = Path();
      final first = at(path[0].x, path[0].y);
      line.moveTo(first.dx, first.dy);
      for (final p in path.skip(1)) {
        final o = at(p.x, p.y);
        line.lineTo(o.dx, o.dy);
      }
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(
        line,
        stroke
          ..strokeWidth = 6
          ..color = AppColors.background.withValues(alpha: 0.85),
      );
      canvas.drawPath(
        line,
        stroke
          ..strokeWidth = 3
          ..color = Colors.white,
      );
    }

    // Scan dots on top, with a white ring so they never melt into the heatmap.
    for (final p in points) {
      final o = at(p.x, p.y);
      canvas.drawCircle(
        o,
        7,
        Paint()..color = AppColors.background.withValues(alpha: 0.9),
      );
      canvas.drawCircle(o, 5.5, Paint()..color = levelColor(p.level));
      canvas.drawCircle(
        o,
        6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white,
      );
    }

    // Where the walk started.
    if (path.isNotEmpty) {
      final s0 = at(path.first.x, path.first.y);
      canvas.drawCircle(s0, 9, Paint()..color = AppColors.good);
      canvas.drawCircle(
        s0,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white,
      );
      final label = TextPainter(
        text: const TextSpan(
          text: 'START',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, s0 + Offset(-label.width / 2, 12));
    }

    // You are here, with a heading wedge.
    final me = at(x, y);
    if (heading != null) {
      final h = heading!;
      final tip = me + Offset(math.sin(h), -math.cos(h)) * 22;
      canvas.drawLine(
        me,
        tip,
        Paint()
          ..color = AppColors.accent
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(
      me,
      11,
      Paint()..color = AppColors.accent.withValues(alpha: 0.3),
    );
    canvas.drawCircle(me, 7, Paint()..color = AppColors.accent);
    canvas.drawCircle(
      me,
      7,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );

    // North marker.
    final tp = TextPainter(
      text: const TextSpan(
        text: 'N ↑',
        style: TextStyle(
          color: AppColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - tp.width - 12, 10));
  }

  @override
  bool shouldRepaint(_TrailPainter old) => true;
}
