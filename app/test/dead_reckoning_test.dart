import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/dead_reckoning.dart';

/// Walking at [hz] steps per second for [seconds], sampled at 50 Hz, with the
/// phone lying flat (gravity on z).
int countSteps(
  StepDetector d, {
  double hz = 2,
  double amplitude = 3,
  double seconds = 10,
}) {
  var steps = 0;
  for (var i = 0; i < seconds * 50; i++) {
    final t = i / 50;
    final az = 9.81 + amplitude * math.sin(2 * math.pi * hz * t);
    if (d.feed((t * 1000).round(), 0.2, 0.1, az)) steps++;
  }
  return steps;
}

void main() {
  group('StepDetector', () {
    test('counts a steady walk', () {
      final steps = countSteps(StepDetector());
      expect(steps, inInclusiveRange(18, 21)); // 2 steps/s for 10 s
    });

    test('ignores a phone lying still', () {
      expect(countSteps(StepDetector(), amplitude: 0), 0);
    });

    test('ignores tiny shakes', () {
      expect(countSteps(StepDetector(), amplitude: 0.3), 0);
    });

    test('never counts two steps closer than the minimum interval', () {
      final steps = countSteps(StepDetector(), hz: 6);
      expect(steps, lessThanOrEqualTo(34)); // 10 s / 0.3 s
    });
  });

  group('headingFromSensors', () {
    double deg(double? r) => r! * 180 / math.pi;

    test('phone flat, top pointing north', () {
      final h = headingFromSensors(0, 0, 9.81, 0, 20, -40);
      expect(deg(h), closeTo(0, 0.01));
    });

    test('top pointing east', () {
      final h = headingFromSensors(0, 0, 9.81, -20, 0, -40);
      expect(deg(h), closeTo(90, 0.01));
    });

    test('top pointing south and west', () {
      expect(
        deg(headingFromSensors(0, 0, 9.81, 0, -20, -40)),
        closeTo(180, 0.01),
      );
      expect(
        deg(headingFromSensors(0, 0, 9.81, 20, 0, -40)),
        closeTo(270, 0.01),
      );
    });

    test('stays correct when the phone is tilted towards you', () {
      // Tilted 30 degrees about the x axis, still facing north.
      const tilt = 30 * math.pi / 180;
      final ay = 9.81 * math.sin(tilt);
      final az = 9.81 * math.cos(tilt);
      // Earth field in the tilted frame: north 20 uT, down 40 uT.
      final my = 20 * math.cos(tilt) + 40 * math.sin(tilt);
      final mz = -40 * math.cos(tilt) + 20 * math.sin(tilt);
      expect(deg(headingFromSensors(0, ay, az, 0, my, mz)), closeTo(0, 0.01));
    });

    test('gives up on a missing field or free fall', () {
      expect(headingFromSensors(0, 0, 9.81, 0, 0, 0), isNull);
      expect(headingFromSensors(0, 0, 0, 0, 20, -40), isNull);
    });
  });

  group('HeadingFilter', () {
    test('starts at the first value', () {
      final f = HeadingFilter();
      expect(f.heading, isNull);
      expect(f.update(1.0), closeTo(1.0, 1e-9));
    });

    test('does not jump the long way round at north', () {
      final f = HeadingFilter(alpha: 0.5);
      f.update(359 * math.pi / 180);
      final h = f.update(1 * math.pi / 180);
      final d = h * 180 / math.pi;
      expect(d < 5 || d > 355, isTrue, reason: 'got $d degrees');
    });
  });

  group('PositionTracker', () {
    test('walks north, east, south, west back to the start', () {
      final t = PositionTracker(stepLengthM: 0.5);
      for (final h in [0.0, math.pi / 2, math.pi, 3 * math.pi / 2]) {
        for (var i = 0; i < 10; i++) {
          t.step(h);
        }
      }
      expect(t.steps, 40);
      expect(t.x, closeTo(0, 1e-9));
      expect(t.y, closeTo(0, 1e-9));
    });

    test('ten steps east is five metres east', () {
      final t = PositionTracker(stepLengthM: 0.5);
      for (var i = 0; i < 10; i++) {
        t.step(math.pi / 2);
      }
      expect(t.x, closeTo(5, 1e-9));
      expect(t.y, closeTo(0, 1e-9));
    });

    test('reanchor snaps to a known position and keeps the step count', () {
      final t = PositionTracker()..step(0);
      t.reanchor(12, -3);
      expect(t.x, 12);
      expect(t.y, -3);
      expect(t.steps, 1);
    });
  });
}
