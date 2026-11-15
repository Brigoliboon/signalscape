import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/levels.dart';
import '../theme.dart';

class TrailPoint {
  const TrailPoint(this.x, this.y, this.level);

  final double x;
  final double y;
  final SignalLevel level;
}

/// The walk so far, one dot per Wi-Fi scan, coloured by signal level. The
/// view re-fits itself as the trail grows; north is up.
class TrailView extends StatelessWidget {
  const TrailView({
    super.key,
    required this.points,
    required this.x,
    required this.y,
    required this.heading,
  });

  final List<TrailPoint> points;
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
          painter: _TrailPainter(points, x, y, heading),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _TrailPainter extends CustomPainter {
  _TrailPainter(this.points, this.x, this.y, this.heading);

  final List<TrailPoint> points;
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
    final span = math.max(20.0, math.max(maxX - minX, maxY - minY));
    const pad = 28.0;
    final scale = (math.min(size.width, size.height) - 2 * pad) / span;
    final cx = (minX + maxX) / 2;
    final cy = (minY + maxY) / 2;
    Offset at(double px, double py) => Offset(
      size.width / 2 + (px - cx) * scale,
      size.height / 2 - (py - cy) * scale,
    );

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

    if (points.length > 1) {
      final path = Path()
        ..moveTo(
          at(points[0].x, points[0].y).dx,
          at(points[0].x, points[0].y).dy,
        );
      for (final p in points.skip(1)) {
        final o = at(p.x, p.y);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.textMuted.withValues(alpha: 0.5),
      );
    }
    for (final p in points) {
      final o = at(p.x, p.y);
      final color = levelColor(p.level);
      canvas.drawCircle(o, 9, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(o, 5, Paint()..color = color);
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
