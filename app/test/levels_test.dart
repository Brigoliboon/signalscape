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
}
