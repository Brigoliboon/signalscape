import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/heatmap.dart';
import 'package:signalscape_mobile/core/levels.dart';
import 'package:signalscape_mobile/core/zones.dart';

void main() {
  const t = Thresholds(goodDbm: -60, deadDbm: -75);

  // One row of three cells: good, weak (fair) and dead, plus one without data.
  const grid = HeatGrid(cols: 4, rows: 1, values: [-50, -70, -90, null]);

  int alphaAt(({int width, int height, dynamic rgba}) p, int px, int py) =>
      p.rgba[(py * p.width + px) * 4 + 3] as int;

  List<int> rgbAt(({int width, int height, dynamic rgba}) p, int px, int py) {
    final i = (py * p.width + px) * 4;
    return [p.rgba[i] as int, p.rgba[i + 1] as int, p.rgba[i + 2] as int];
  }

  group('zone layer (FR-26)', () {
    test('legend text follows the thresholds', () {
      expect(weakZoneText(t), 'Weak: -75 to -60 dBm');
      expect(deadZoneText(t), 'Dead: below -75 dBm');
      expect(weakZoneText(const Thresholds()), 'Weak: -80 to -67 dBm');
      expect(deadZoneText(const Thresholds()), 'Dead: below -80 dBm');
    });

    test('weak is amber, dead is red, good and empty cells stay clear', () {
      final p = zonesRgba(grid, t);
      const s = zonePixelsPerCell;
      expect(p.width, (4 + 2 * padCells) * s);
      expect(p.height, (1 + 2 * padCells) * s);
      final y = padCells * s + 1; // inside the only row
      int x(int col) => (col + padCells) * s + 3;
      expect(alphaAt(p, x(0), y), 0); // good
      expect(alphaAt(p, x(3), y), 0); // no data
      expect(alphaAt(p, 0, 0), 0); // the blank border
      expect(rgbAt(p, x(1), y), [0xFB, 0xBF, 0x24]);
      expect(alphaAt(p, x(1), y), (zoneAlpha * 255).round());
      expect(rgbAt(p, x(2), y), [0xFB, 0x71, 0x85]);
    });

    test('dead zones are hatched, weak zones are not', () {
      final p = zonesRgba(grid, t);
      const s = zonePixelsPerCell;
      final y = padCells * s;
      final deadAlphas = {
        for (var px = (2 + padCells) * s; px < (3 + padCells) * s; px++)
          alphaAt(p, px, y),
      };
      expect(deadAlphas, {
        (zoneAlpha * 255).round(),
        (zoneHatchAlpha * 255).round(),
      });
      final weakAlphas = {
        for (var px = (1 + padCells) * s; px < (2 + padCells) * s; px++)
          alphaAt(p, px, y),
      };
      expect(weakAlphas, {(zoneAlpha * 255).round()});
    });

    test('changing the thresholds changes the zones', () {
      // -70 is weak with a -60 good threshold, good with -72.
      const looser = Thresholds(goodDbm: -72, deadDbm: -95);
      final p = zonesRgba(grid, looser);
      const s = zonePixelsPerCell;
      final y = padCells * s + 1;
      expect(alphaAt(p, (1 + padCells) * s + 3, y), 0);
      // -90 is now weak, not dead: amber
      expect(rgbAt(p, (2 + padCells) * s + 3, y), [0xFB, 0xBF, 0x24]);
    });

    test('row 0 of the picture is the north row', () {
      const twoRows = HeatGrid(cols: 1, rows: 2, values: [-90, -50]);
      final p = zonesRgba(twoRows, t);
      const s = zonePixelsPerCell;
      final x = padCells * s + 3;
      // south row (row 0, dead) is drawn lower in the picture
      expect(alphaAt(p, x, (padCells + 1) * s + 3) > 0, isTrue);
      expect(alphaAt(p, x, padCells * s + 3), 0);
    });

    test('big grids use fewer pixels per cell', () {
      final big = HeatGrid(
        cols: 1000,
        rows: 2,
        values: List<double?>.filled(2000, -90),
      );
      final p = zonesRgba(big, t);
      expect(p.width, lessThanOrEqualTo(maxImageSide));
    });

    test('no PNG when nothing is weak or dead', () {
      expect(
        renderZonesPng(const HeatGrid(cols: 1, rows: 1, values: [-40]), t),
        isNull,
      );
      expect(renderZonesPng(grid, t), isNotNull);
    });
  });
}
