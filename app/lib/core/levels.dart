/// Signal levels (FR-15). Same rule as the API: good at or above the good
/// threshold, dead below the dead threshold, fair in between.
enum SignalLevel { good, fair, dead }

class Thresholds {
  const Thresholds({this.goodDbm = -67, this.deadDbm = -80});

  final int goodDbm;
  final int deadDbm;

  @override
  bool operator ==(Object other) =>
      other is Thresholds &&
      other.goodDbm == goodDbm &&
      other.deadDbm == deadDbm;

  @override
  int get hashCode => Object.hash(goodDbm, deadDbm);
}

SignalLevel levelFor(num rssiDbm, Thresholds t) {
  if (rssiDbm >= t.goodDbm) return SignalLevel.good;
  if (rssiDbm >= t.deadDbm) return SignalLevel.fair;
  return SignalLevel.dead;
}

/// How much of a cell's full opacity it keeps at confidence 0, so even a cell
/// built from one distant reading can still be seen.
const double minConfidenceShare = 0.3;

/// How sure the API is of a cell, 0 to 1 (see its `confidence`): few or distant
/// readings give less. A missing or unreadable value is 1, which is what grids
/// processed before confidence existed mean.
double confidenceOf(Object? raw) =>
    raw is num && !raw.isNaN ? raw.toDouble().clamp(0.0, 1.0) : 1.0;

/// Opacity for a cell: [full] at confidence 1, fading to [minConfidenceShare]
/// of it at confidence 0.
double confidenceAlpha(double confidence, {required double full}) =>
    full *
    (minConfidenceShare +
        (1 - minConfidenceShare) * confidence.clamp(0.0, 1.0));

String levelName(SignalLevel level) => switch (level) {
  SignalLevel.good => 'Good',
  SignalLevel.fair => 'Fair',
  SignalLevel.dead => 'Dead',
};
