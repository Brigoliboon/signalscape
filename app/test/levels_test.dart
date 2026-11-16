import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/levels.dart';

void main() {
  const t = Thresholds(); // -67 good, -80 dead, same defaults as the API

  test('defaults match the API', () {
    expect(t.goodDbm, -67);
    expect(t.deadDbm, -80);
  });

  test('good at or above the good threshold', () {
    expect(levelFor(-30, t), SignalLevel.good);
    expect(levelFor(-67, t), SignalLevel.good);
    expect(levelFor(-67.1, t), SignalLevel.fair);
  });

  test('fair between the thresholds, dead strictly below', () {
    expect(levelFor(-70, t), SignalLevel.fair);
    expect(levelFor(-80, t), SignalLevel.fair);
    expect(levelFor(-80.1, t), SignalLevel.dead);
    expect(levelFor(-95, t), SignalLevel.dead);
  });

  test('uses the surveyor thresholds', () {
    const strict = Thresholds(goodDbm: -55, deadDbm: -70);
    expect(levelFor(-60, strict), SignalLevel.fair);
    expect(levelFor(-72, strict), SignalLevel.dead);
    expect(strict == const Thresholds(goodDbm: -55, deadDbm: -70), isTrue);
  });

  test('names are text, not only colour', () {
    expect(levelName(SignalLevel.good), 'Good');
    expect(levelName(SignalLevel.fair), 'Fair');
    expect(levelName(SignalLevel.dead), 'Dead');
  });

  group('confidence', () {
    test('a missing or unreadable value is full confidence', () {
      expect(confidenceOf(null), 1.0);
      expect(confidenceOf('0.2'), 1.0);
      expect(confidenceOf(double.nan), 1.0);
      expect(confidenceOf(0.4), 0.4);
      expect(confidenceOf(1), 1.0);
      expect(confidenceOf(-3), 0.0);
      expect(confidenceOf(7), 1.0);
    });

    test('alpha fades from full to 30% of it', () {
      expect(confidenceAlpha(1, full: 0.75), closeTo(0.75, 1e-9));
      expect(
        confidenceAlpha(0, full: 0.75),
        closeTo(0.75 * minConfidenceShare, 1e-9),
      );
      expect(
        confidenceAlpha(0.5, full: 1),
        closeTo(minConfidenceShare + (1 - minConfidenceShare) / 2, 1e-9),
      );
      // out of range values are clamped
      expect(confidenceAlpha(2, full: 1), 1.0);
      expect(confidenceAlpha(-1, full: 1), closeTo(minConfidenceShare, 1e-9));
    });
  });
}
