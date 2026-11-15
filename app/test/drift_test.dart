import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/drift.dart';

void main() {
  test('share grows in a straight line with the steps walked', () {
    expect(driftShare(0, 0, 100), 0);
    expect(driftShare(25, 0, 100), 0.25);
    expect(driftShare(100, 0, 100), 1);
    expect(driftShare(50, 40, 140), 0.1);
  });

  test('share is clamped outside the walk', () {
    expect(driftShare(-5, 0, 10), 0);
    expect(driftShare(20, 0, 10), 1);
  });

  test('no steps since the last checkpoint: only points right here move', () {
    expect(driftShare(10, 10, 10), 1);
    expect(driftShare(9, 10, 10), 0);
  });

  test('the path ends exactly on the checkpoint and starts untouched', () {
    // 10 steps east; the checkpoint says we are 1 m east and 2 m north of
    // where dead reckoning put us.
    final pts = [
      for (var i = 0; i <= 10; i++) DriftPoint(i.toDouble(), 0, i.toDouble()),
    ];
    final out = spreadDrift(pts, 1, 2, startProgress: 0, endProgress: 10);
    expect(out.first.x, 0);
    expect(out.first.y, 0);
    expect(out.last.x, 11);
    expect(out.last.y, 2);
    expect(out[5].x, closeTo(5.5, 1e-9));
    expect(out[5].y, closeTo(1.0, 1e-9));
  });

  test('points of one scan share a place and the same correction', () {
    final out = spreadDrift(
      const [DriftPoint(3, 3, 5), DriftPoint(3, 3, 5), DriftPoint(8, 8, 10)],
      0,
      10,
      startProgress: 0,
      endProgress: 10,
    );
    expect(out[0].y, out[1].y);
    expect(out[0].y, closeTo(3 + 5, 1e-9));
    expect(out[2].y, closeTo(18, 1e-9));
  });

  test('zero error leaves everything where it was', () {
    const pts = [DriftPoint(1, 2, 3), DriftPoint(4, 5, 6)];
    final out = spreadDrift(pts, 0, 0, startProgress: 0, endProgress: 6);
    expect([for (final p in out) (p.x, p.y)], [(1.0, 2.0), (4.0, 5.0)]);
  });

  test('an empty list stays empty', () {
    expect(
      spreadDrift(const [], 1, 1, startProgress: 0, endProgress: 1),
      isEmpty,
    );
  });
}
