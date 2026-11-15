import 'dart:math' as math;

/// Height of each floor, for turning a pressure change into a floor change.
///
/// `heights` maps a floor level to that floor's height in metres. A level that
/// is missing, or has no height, uses [fallbackM]; real storeys are about
/// 3 to 3.5 m, so the default is in the middle.
class FloorStack {
  FloorStack({
    required Iterable<int> levels,
    Map<int, double> heights = const {},
    this.fallbackM = 3.3,
  }) : levels = (levels.toSet().toList()..sort()),
       _heights = {
         for (final e in heights.entries)
           if (e.value > 0) e.key: e.value,
       };

  final List<int> levels;
  final Map<int, double> _heights;
  final double fallbackM;

  double heightOf(int level) => _heights[level] ?? fallbackM;

  /// Elevation of the floor at [level] above the floor at level 0, in metres.
  double elevationOf(int level) {
    var sum = 0.0;
    if (level > 0) {
      for (var k = 0; k < level; k++) {
        sum += heightOf(k);
      }
    } else {
      for (var k = level; k < 0; k++) {
        sum -= heightOf(k);
      }
    }
    return sum;
  }
}

/// Height change in metres when the pressure goes from [basePa] to [pa]
/// (both in hPa). Positive means higher up. Uses the standard-atmosphere
/// formula, which near sea level is about 8.4 m per hPa.
double altitudeDelta(double basePa, double pa) =>
    44330.0 * (1 - math.pow(pa / basePa, 1 / 5.255));

/// Works out which floor the phone is on from air pressure (FR-9).
///
/// 1. [calibrate] on the floor the surveyor starts on. The first
///    [calibrationSamples] readings are averaged into a base pressure.
/// 2. [feed] each reading. The pressure is smoothed, turned into an elevation
///    above the base floor and matched to the nearest floor in [stack].
/// 3. To avoid flicker a different floor must be clearly closer
///    (by [marginFraction] of a floor height) for [dwellMs] before it is
///    reported. Standing on a landing or on a stair step does not switch.
///
/// Weather moves pressure slowly, so [confirm] re-bases on the floor a person
/// says they are on (a manual override), which also removes any drift.
class BarometerFloorTracker {
  BarometerFloorTracker({
    required this.stack,
    this.calibrationSamples = 15,
    this.dwellMs = 3000,
    this.marginFraction = 0.25,
    this.smoothing = 0.15,
  });

  FloorStack stack;
  final int calibrationSamples;
  final int dwellMs;
  final double marginFraction;
  final double smoothing;

  int? _level;
  double? _basePa;
  double _baseElevation = 0;
  double? _smooth;
  final List<double> _calib = [];
  int? _pendingLevel;
  int _pendingSince = 0;

  /// The floor the tracker currently believes in, once calibration started.
  int? get level => _level;
  bool get calibrated => _basePa != null;

  /// Estimated elevation above floor 0, once calibrated.
  double? get elevationM => (_basePa == null || _smooth == null)
      ? null
      : _baseElevation + altitudeDelta(_basePa!, _smooth!);

  /// Starts collecting calibration samples for a phone standing on [level].
  void calibrate(int level) {
    _level = level;
    _basePa = null;
    _smooth = null;
    _calib.clear();
    _pendingLevel = null;
  }

  /// Re-bases on the latest pressure for the floor a person chose by hand.
  void confirm(int level) {
    _level = level;
    _pendingLevel = null;
    final s = _smooth;
    if (s != null && _basePa != null) {
      _basePa = s;
      _baseElevation = stack.elevationOf(level);
    } else if (_basePa == null) {
      calibrate(level);
    }
  }

  /// Feeds one reading in hPa taken at [tMs]. Returns the new floor level when
  /// a floor change is detected, otherwise null.
  int? feed(int tMs, double hPa) {
    if (hPa < 300 || hPa > 1100 || hPa.isNaN) return null;
    if (_level == null) return null;
    _smooth = _smooth == null ? hPa : _smooth! + smoothing * (hPa - _smooth!);
    if (_basePa == null) {
      _calib.add(hPa);
      if (_calib.length >= calibrationSamples) {
        _basePa = _calib.reduce((a, b) => a + b) / _calib.length;
        _baseElevation = stack.elevationOf(_level!);
        _smooth = _basePa;
        _calib.clear();
      }
      return null;
    }
    final elev = elevationM!;
    final current = _level!;
    final currentGap = (elev - stack.elevationOf(current)).abs();
    int best = current;
    var bestGap = currentGap;
    for (final l in stack.levels) {
      final gap = (elev - stack.elevationOf(l)).abs();
      if (gap < bestGap) {
        best = l;
        bestGap = gap;
      }
    }
    final margin = marginFraction * stack.heightOf(current);
    if (best == current || currentGap - bestGap < margin) {
      _pendingLevel = null;
      return null;
    }
    if (_pendingLevel != best) {
      _pendingLevel = best;
      _pendingSince = tMs;
      return null;
    }
    if (tMs - _pendingSince >= dwellMs) {
      _level = best;
      _pendingLevel = null;
      return best;
    }
    return null;
  }
}
