import 'dart:math' as math;

/// Counts steps from raw accelerometer samples (m/s², gravity included).
///
/// The magnitude is smoothed lightly, a slow average (gravity) is subtracted,
/// and a step is a local peak above [threshold] at least [minIntervalMs] after
/// the previous one.
class StepDetector {
  StepDetector({this.threshold = 1.1, this.minIntervalMs = 300});

  final double threshold;
  final int minIntervalMs;

  double? _gravity;
  double _smooth = 0;
  double _prev = 0;
  double _prev2 = 0;
  int _lastStepMs = -1 << 30;

  /// Feeds one sample taken at [tMs]. Returns true when it completes a step.
  bool feed(int tMs, double ax, double ay, double az) {
    final m = math.sqrt(ax * ax + ay * ay + az * az);
    if (_gravity == null) {
      _gravity = m;
      _smooth = m;
      return false;
    }
    _gravity = _gravity! + 0.02 * (m - _gravity!);
    _smooth += 0.3 * (m - _smooth);
    final dyn = _smooth - _gravity!;
    final peak = _prev > threshold && _prev >= _prev2 && _prev > dyn;
    _prev2 = _prev;
    _prev = dyn;
    if (peak && tMs - _lastStepMs >= minIntervalMs) {
      _lastStepMs = tMs;
      return true;
    }
    return false;
  }
}

/// Compass heading in radians, clockwise from magnetic north, of the phone's
/// top edge. Tilt-compensated with the accelerometer (same maths as Android's
/// `getRotationMatrix`). Returns null when the readings are unusable.
double? headingFromSensors(
  double ax,
  double ay,
  double az,
  double mx,
  double my,
  double mz,
) {
  var hx = my * az - mz * ay;
  var hy = mz * ax - mx * az;
  var hz = mx * ay - my * ax;
  final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
  if (normH < 0.1) return null;
  final normA = math.sqrt(ax * ax + ay * ay + az * az);
  if (normA < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final nax = ax / normA;
  final naz = az / normA;
  final northY = naz * hx - nax * hz;
  final heading = math.atan2(hy, northY);
  return heading < 0 ? heading + 2 * math.pi : heading;
}

/// Smooths a heading on the circle, so it does not jump at 0 / 360 degrees.
class HeadingFilter {
  HeadingFilter({this.alpha = 0.15});

  final double alpha;
  double? _s;
  double? _c;

  double? get heading => _s == null ? null : _normalize(math.atan2(_s!, _c!));

  double update(double radians) {
    final s = math.sin(radians);
    final c = math.cos(radians);
    if (_s == null) {
      _s = s;
      _c = c;
    } else {
      _s = _s! + alpha * (s - _s!);
      _c = _c! + alpha * (c - _c!);
    }
    return heading!;
  }

  static double _normalize(double r) => r < 0 ? r + 2 * math.pi : r;
}

/// Position in metres (x east, y north) from the survey origin.
class PositionTracker {
  PositionTracker({this.stepLengthM = 0.7});

  final double stepLengthM;
  double x = 0;
  double y = 0;
  int steps = 0;

  /// One step of [stepLengthM] towards [headingRad].
  void step(double headingRad) {
    x += stepLengthM * math.sin(headingRad);
    y += stepLengthM * math.cos(headingRad);
    steps++;
  }

  /// Snaps to a known position (a good GPS fix at a checkpoint).
  void reanchor(double newX, double newY) {
    x = newX;
    y = newY;
  }
}
