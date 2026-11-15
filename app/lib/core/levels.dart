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

String levelName(SignalLevel level) => switch (level) {
  SignalLevel.good => 'Good',
  SignalLevel.fair => 'Fair',
  SignalLevel.dead => 'Dead',
};
