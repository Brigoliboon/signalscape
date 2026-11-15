import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/barometer.dart';

/// Pressure at [dh] metres above a base of [base] hPa, from the same
/// standard-atmosphere formula the tracker inverts.
double pressureAt(double base, double dh) =>
    base * math.pow(1 - dh / 44330.0, 5.255);

void main() {
  group('FloorStack', () {
    test('elevation adds up the floor heights above and below ground', () {
      final s = FloorStack(
        levels: [-1, 0, 1, 2],
        heights: {-1: 3.5, 0: 4.0, 1: 3.0},
      );
      expect(s.elevationOf(0), 0);
      expect(s.elevationOf(1), 4.0);
      expect(s.elevationOf(2), 7.0);
      expect(s.elevationOf(3), 7.0 + 3.3); // level 2 has no height: fallback
      expect(s.elevationOf(-1), -3.5);
      expect(s.elevationOf(-2), -3.5 - 3.3);
    });

    test('non-positive heights are ignored', () {
      final s = FloorStack(levels: [0, 1], heights: {0: 0, 1: -2});
      expect(s.heightOf(0), 3.3);
      expect(s.heightOf(1), 3.3);
    });

    test('levels are sorted and unique', () {
      expect(FloorStack(levels: [2, 0, 2, 1]).levels, [0, 1, 2]);
    });
  });

  group('altitudeDelta', () {
    test('is about 8.4 m per hPa near sea level, up when pressure drops', () {
      expect(altitudeDelta(1013.25, 1012.25), closeTo(8.4, 0.2));
      expect(altitudeDelta(1013.25, 1014.25), closeTo(-8.4, 0.2));
      expect(altitudeDelta(1000, 1000), 0);
    });
  });

  group('BarometerFloorTracker', () {
    const base = 1005.0;
    final stack = FloorStack(
      levels: [0, 1, 2],
      heights: {0: 3.0, 1: 3.0, 2: 3.0},
    );

    BarometerFloorTracker tracker() => BarometerFloorTracker(
      stack: stack,
      calibrationSamples: 5,
      dwellMs: 2000,
    );

    /// Feeds [seconds] of samples at 5 Hz taken [dh] metres above the base
    /// floor. Returns the last floor change reported, if any.
    int? hold(BarometerFloorTracker t, double dh, int fromMs, int seconds) {
      int? last;
      for (var ms = 0; ms < seconds * 1000; ms += 200) {
        final r = t.feed(fromMs + ms, pressureAt(base, dh));
        if (r != null) last = r;
      }
      return last;
    }

    test('ignores samples until it is told which floor it is on', () {
      expect(tracker().feed(0, 1000), isNull);
    });

    test('calibrates on the start floor and reports no change', () {
      final t = tracker()..calibrate(1);
      expect(t.calibrated, isFalse);
      expect(hold(t, 0, 0, 3), isNull);
      expect(t.calibrated, isTrue);
      expect(t.level, 1);
      expect(t.elevationM, closeTo(3.0, 0.1)); // level 1 sits 3 m up
    });

    test('goes up one floor after a steady climb', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      expect(hold(t, 3.0, 4000, 8), 1);
      expect(t.level, 1);
    });

    test('goes up two floors and back down', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      expect(hold(t, 6.0, 4000, 12), 2);
      expect(hold(t, 0.0, 20000, 12), 0);
    });

    test('a half-floor stop on a landing does not switch', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      expect(hold(t, 1.2, 4000, 10), isNull);
      expect(t.level, 0);
    });

    test('must stay on the new floor for the dwell time', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      expect(hold(t, 3.0, 4000, 1), isNull);
      expect(hold(t, 0, 5000, 5), isNull);
      expect(t.level, 0);
    });

    test('hysteresis: sitting between floors does not flip back', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      expect(hold(t, 3.0, 4000, 8), 1);
      // 1.4 m is nearer floor 0 than floor 1 by only 0.2 m (margin is 0.75).
      expect(hold(t, 1.4, 14000, 10), isNull);
      expect(t.level, 1);
    });

    test('never reports a level the building does not have', () {
      final t = tracker()..calibrate(2);
      hold(t, 0, 0, 3);
      expect(hold(t, 9.0, 4000, 12), isNull); // would be level 5
      expect(t.level, 2);
    });

    test('manual override re-bases, so weather drift is forgotten', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      // A weather front drops the pressure by about 3 m worth: it looks like
      // a floor change...
      expect(hold(t, 3.0, 4000, 8), 1);
      // ...the person says "I am on 0", so the tracker re-bases there.
      t.confirm(0);
      expect(t.level, 0);
      expect(hold(t, 3.0, 12000, 10), isNull);
      expect(t.level, 0);
    });

    test('confirm before calibration starts calibrating', () {
      final t = tracker()..confirm(2);
      expect(t.level, 2);
      hold(t, 0, 0, 3);
      expect(t.calibrated, isTrue);
    });

    test('uses each floor height', () {
      final tall = FloorStack(levels: [0, 1], heights: {0: 5.0, 1: 3.0});
      final t = BarometerFloorTracker(
        stack: tall,
        calibrationSamples: 5,
        dwellMs: 2000,
      )..calibrate(0);
      hold(t, 0, 0, 3);
      // Floor 1 is 5 m up, so 3 m is not enough (half way is 2.5 m + margin).
      expect(hold(t, 2.0, 4000, 8), isNull);
      expect(hold(t, 5.0, 14000, 8), 1);
    });

    test('rejects impossible pressures', () {
      final t = tracker()..calibrate(0);
      expect(t.feed(0, 0), isNull);
      expect(t.feed(1, double.nan), isNull);
      expect(t.feed(2, 5000), isNull);
      expect(t.calibrated, isFalse);
    });

    test('calibrate again starts over', () {
      final t = tracker()..calibrate(0);
      hold(t, 0, 0, 3);
      t.calibrate(1);
      expect(t.calibrated, isFalse);
      expect(t.level, 1);
    });
  });
}
