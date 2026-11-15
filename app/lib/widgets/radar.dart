import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// A rotating radar sweep with expanding rings. It runs while [active] and
/// freezes when not. [pulse] (0 to 1) lights the centre after a Wi-Fi scan.
class Radar extends StatefulWidget {
  const Radar({
    super.key,
    required this.active,
    this.pulse = 0,
    this.size = 56,
  });

  final bool active;
  final double pulse;
  final double size;

  @override
  State<Radar> createState() => _RadarState();
}

class _RadarState extends State<Radar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(Radar old) {
    super.didUpdateWidget(old);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, _) => CustomPaint(
            painter: _RadarPainter(
              _controller.value,
              widget.active,
              widget.pulse,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.t, this.active, this.pulse);

  final double t;
  final bool active;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = AppColors.accent.withValues(alpha: 0.35);
    for (final f in const [1.0, 0.66, 0.33]) {
      canvas.drawCircle(c, r * f - 0.6, ring);
    }
    if (active) {
      // Sweep: a fading wedge behind a bright leading line.
      final angle = t * 2 * math.pi;
      final rect = Rect.fromCircle(center: c, radius: r);
      final sweep = Paint()
        ..shader = SweepGradient(
          startAngle: 0,
          endAngle: 2 * math.pi,
          colors: [
            AppColors.accent.withValues(alpha: 0),
            AppColors.accent.withValues(alpha: 0.55),
          ],
          stops: const [0.7, 1.0],
          transform: GradientRotation(angle - 2 * math.pi),
        ).createShader(rect);
      canvas.drawCircle(c, r - 1, sweep);
      canvas.drawLine(
        c,
        c + Offset(math.cos(angle), math.sin(angle)) * (r - 1),
        Paint()
          ..color = AppColors.accent
          ..strokeWidth = 2,
      );
      // An expanding ping ring.
      canvas.drawCircle(
        c,
        r * t,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = AppColors.accent.withValues(alpha: (1 - t) * 0.5),
      );
    }
    final dot = active ? AppColors.accent : AppColors.textMuted;
    if (pulse > 0) {
      canvas.drawCircle(
        c,
        4 + 10 * pulse,
        Paint()..color = AppColors.good.withValues(alpha: 0.45 * pulse),
      );
    }
    canvas.drawCircle(c, 4, Paint()..color = dot);
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.t != t || old.active != active || old.pulse != pulse;
}
