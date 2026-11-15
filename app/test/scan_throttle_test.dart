import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/scan_throttle.dart';

void main() {
  final t0 = DateTime(2026, 11, 16, 9);

  test('allows four scans, then makes you wait for the oldest to age out', () {
    final th = ScanThrottle();
    for (var i = 0; i < 4; i++) {
      final now = t0.add(Duration(seconds: i * 5));
      expect(th.canScan(now), isTrue);
      th.recordStart(now);
    }
    final now = t0.add(const Duration(seconds: 20));
    expect(th.canScan(now), isFalse);
    expect(th.usedIn(now), 4);
    expect(th.waitFor(now), const Duration(seconds: 100));
  });

  test('a scan frees up two minutes after it started', () {
    final th = ScanThrottle();
    for (var i = 0; i < 4; i++) {
      th.recordStart(t0.add(Duration(seconds: i)));
    }
    expect(th.canScan(t0.add(const Duration(seconds: 119))), isFalse);
    expect(th.canScan(t0.add(const Duration(seconds: 120))), isTrue);
    expect(th.usedIn(t0.add(const Duration(seconds: 120))), 3);
  });

  test('backs off after the system refuses a scan', () {
    final th = ScanThrottle();
    th.recordRefusal(t0);
    expect(th.canScan(t0.add(const Duration(seconds: 10))), isFalse);
    expect(
      th.waitFor(t0.add(const Duration(seconds: 10))),
      const Duration(seconds: 20),
    );
    expect(th.canScan(t0.add(const Duration(seconds: 30))), isTrue);
  });

  test('waits for whichever limit is longer', () {
    final th = ScanThrottle();
    for (var i = 0; i < 4; i++) {
      th.recordStart(t0);
    }
    th.recordRefusal(t0.add(const Duration(seconds: 100)));
    final now = t0.add(const Duration(seconds: 110));
    expect(th.waitFor(now), const Duration(seconds: 20));
  });
}
