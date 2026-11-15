/// One position estimated by dead reckoning, in metres from the survey origin.
/// [progress] says how far along the walk it was (the step count), so points
/// from one scan, which share a place, get the same correction.
class DriftPoint {
  const DriftPoint(this.x, this.y, this.progress);

  final double x;
  final double y;
  final double progress;
}

/// Share of a checkpoint's error that belongs to a point, 0 to 1.
double driftShare(double progress, double startProgress, double endProgress) {
  final span = endProgress - startProgress;
  // Nobody walked since the last checkpoint: only points taken right here
  // share the error.
  if (span <= 0) return progress >= endProgress ? 1 : 0;
  return ((progress - startProgress) / span).clamp(0.0, 1.0);
}

/// Spreads the error found at a checkpoint back over the positions recorded
/// since the previous checkpoint (FR-10).
///
/// Dead reckoning drifts a little more with every step. When a checkpoint
/// shows that the estimate is off by ([errX], [errY]) metres, the position at
/// the checkpoint was off by all of that, the one at the previous checkpoint
/// by none, and the ones in between by a share that grows in a straight line
/// with the steps walked. The corrected path therefore ends exactly on the
/// checkpoint and bends smoothly towards it.
List<DriftPoint> spreadDrift(
  List<DriftPoint> points,
  double errX,
  double errY, {
  required double startProgress,
  required double endProgress,
}) => [
  for (final p in points)
    () {
      final w = driftShare(p.progress, startProgress, endProgress);
      return DriftPoint(p.x + errX * w, p.y + errY * w, p.progress);
    }(),
];
