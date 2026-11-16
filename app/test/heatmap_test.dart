import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:signalscape_mobile/core/heatmap.dart';
import 'package:signalscape_mobile/core/map_data.dart';
import 'package:signalscape_mobile/core/png.dart';

import 'map_data_test.dart' show cell, collection;

/// A picture built by hand: row 0 = top.
HeatField field(
  int width,
  int height,
  List<num> value, {
  List<num>? coverage,
  List<num>? confidence,
}) => HeatField(
  width: width,
  height: height,
  factor: 1,
  value: Float32List.fromList([for (final v in value) v.toDouble()]),
  coverage: Float32List.fromList([
    for (final v in coverage ?? List.filled(value.length, 1.0)) v.toDouble(),
  ]),
  confidence: Float32List.fromList([
    for (final v in confidence ?? List.filled(value.length, 1.0)) v.toDouble(),
  ]),
);

const nan = double.nan;

void main() {
  group('colour ramp', () {
    test('red at -30, green at -67, dark blue at -100, clamped outside', () {
      expect(rampColor(-30), [0xe3, 0x21, 0x1c]);
      expect(rampColor(-67), [0x38, 0xb5, 0x4a]);
      expect(rampColor(-100), [0x1b, 0x21, 0x66]);
      expect(rampColor(-10), rampColor(-30));
      expect(rampColor(-120), rampColor(-100));
      for (final s in rampStops) {
        expect(rampColor(s.dbm.toDouble()), [s.r, s.g, s.b]);
      }
    });

    test('blends linearly between stops', () {
      // -51 is halfway between orange (-45) and yellow (-57).
      expect(rampColor(-51), [
        ((0xf7 + 0xfb) / 2).round(),
        ((0x86 + 0xe5) / 2).round(),
        ((0x1e + 0x1a) / 2).round(),
      ]);
    });

    test('stops run strong to weak and the legend ticks lie on the bar', () {
      final dbm = rampStops.map((s) => s.dbm).toList();
      expect([...dbm]..sort((a, b) => b.compareTo(a)), dbm);
      expect(rampFraction(-30), 0);
      expect(rampFraction(-100), 1);
      expect(rampFraction(-65), 0.5);
      expect(legendTicks.every((t) => t <= -30 && t >= -100), isTrue);
    });
  });

  group('upsampling', () {
    test('the picture has one blank cell all round', () {
      final f = upsampleGrid(
        const HeatGrid(cols: 2, rows: 2, values: [-60, -60, -60, -60]),
        factor: 4,
      );
      expect((f.width, f.height, f.factor), (16, 16, 4));
      // A constant field stays constant wherever there is anything, and is
      // fully solid between the centres of the data cells (pixels 6 to 9).
      for (var i = 0; i < f.value.length; i++) {
        if (f.coverage[i] > 0) expect(f.value[i], closeTo(-60, 1e-4));
      }
      for (var y = 6; y < 10; y++) {
        for (var x = 6; x < 10; x++) {
          expect(f.coverage[y * 16 + x], closeTo(1, 1e-6));
        }
      }
      expect(f.coverage[0], 0);
      expect(f.coverage[8 * 16 + 1], 0);
      expect(f.coverage[8 * 16 + 3], inExclusiveRange(0, 0.5));
    });

    test('values blend bilinearly, south row first, picture north up', () {
      final f = upsampleGrid(
        const HeatGrid(cols: 2, rows: 2, values: [-40, -40, -80, -80]),
        factor: 4,
      );
      double at(int x, int y) => f.value[y * f.width + x];
      expect(at(8, 9), greaterThan(at(8, 6))); // south is at the bottom
      expect(at(8, 8), inExclusiveRange(-80, -40));
    });

    test('empty cells are left out, so colour never bleeds into them', () {
      final values = List<double?>.filled(9, null);
      values[4] = -50;
      final f = upsampleGrid(
        HeatGrid(cols: 3, rows: 3, values: values),
        factor: 5,
      );
      for (var i = 0; i < f.value.length; i++) {
        if (f.coverage[i] > 0) {
          expect(f.value[i], closeTo(-50, 1e-3));
        } else {
          expect(f.value[i].isNaN, isTrue);
        }
      }
      // Solid at the cell's centre, nothing at the picture's corner, and the
      // fade ends inside the blank border.
      expect(f.coverage[(f.height ~/ 2) * f.width + f.width ~/ 2], 1.0);
      expect(f.coverage[0], 0);
      for (var x = 0; x < f.width; x++) {
        expect(f.coverage[x], 0);
        expect(f.coverage[(f.height - 1) * f.width + x], 0);
      }
    });

    test('confidence is taken only from cells that have data', () {
      final f = upsampleGrid(
        const HeatGrid(
          cols: 2,
          rows: 1,
          values: [-60, null],
          confidence: [0.2, 1],
        ),
        factor: 4,
      );
      final row = f.height ~/ 2;
      for (var x = 0; x < f.width; x++) {
        final i = row * f.width + x;
        if (f.coverage[i] > 0) expect(f.confidence[i], closeTo(0.2, 1e-5));
      }
    });

    test('a missing confidence reads as full', () {
      final f = upsampleGrid(
        const HeatGrid(cols: 1, rows: 1, values: [-60]),
        factor: 2,
      );
      expect(f.confidence.reduce((a, b) => a > b ? a : b), closeTo(1, 1e-6));
    });

    test('the picture stays within the size cap', () {
      expect(chooseFactor(10, 10), 6);
      expect(chooseFactor(998, 20), 2); // (998 + 2) cells x 2 px = 2000
      expect(chooseFactor(5000, 5000), 1);
      final big = upsampleGrid(
        HeatGrid(
          cols: 300,
          rows: 300,
          values: List<double?>.filled(300 * 300, -60),
        ),
        factor: 8,
      );
      expect(big.width, lessThanOrEqualTo(maxImageSide));
      expect(big.height, lessThanOrEqualTo(maxImageSide));
    });
  });

  group('colouring', () {
    final f = field(
      5,
      1,
      [-30, -95, -35, -35, nan],
      coverage: [1, 1, 0.5, 1, 0],
      confidence: [1, 1, 1, 0, 1],
    );

    test('ramp colour, soft edge and confidence fade', () {
      final px = renderHeatRgba(f);
      expect(px.sublist(0, 4), [0xe3, 0x21, 0x1c, 255]);
      expect(px.sublist(4, 7), rampColor(-95));
      expect(px[2 * 4 + 3], 128, reason: 'half coverage is half opaque');
      expect(
        px[3 * 4 + 3],
        (255 * 0.3).round(),
        reason: 'confidence 0 keeps 30%',
      );
      expect(px[4 * 4 + 3], 0, reason: 'no data is transparent');
    });

    test('values below the minimum are transparent', () {
      expect(renderHeatRgba(f, minRssi: -60)[1 * 4 + 3], 0);
      expect(renderHeatRgba(f, minRssi: -60)[3], 255);
      expect(renderHeatRgba(f, minRssi: -95)[1 * 4 + 3], 255);
    });

    test('opacity scales every pixel', () {
      expect(renderHeatRgba(f, opacity: 0.5)[3], 128);
    });
  });

  group('contours (marching squares)', () {
    test('one straight line per level on a known ramp', () {
      // -60 on the left, -40 on the right: -55, -50 and -45 cross it.
      final f = field(2, 2, [-60, -40, -60, -40]);
      final seg = contourSegments(f);
      expect(seg.length / 4, 3);
      final xs = <double>[];
      for (var i = 0; i < seg.length; i += 4) {
        expect(seg[i], closeTo(seg[i + 2], 1e-6), reason: 'vertical');
        expect((seg[i + 1] - seg[i + 3]).abs(), closeTo(1, 1e-6));
        xs.add(((seg[i] - 0.5) * 100).roundToDouble() / 100);
      }
      // Pixel centres are at 0.5 and 1.5; the field crosses at 1/4, 1/2, 3/4.
      expect(xs..sort(), [0.25, 0.5, 0.75]);
      expect(contourSegments(f, step: 10).length / 4, 1);
      expect(contourSegments(f, step: 0), isEmpty);
    });

    test('goes round a peak and leaves flat areas alone', () {
      final peak = field(3, 3, [-70, -70, -70, -70, -40, -70, -70, -70, -70]);
      expect(contourSegments(peak).length / 4, greaterThanOrEqualTo(8));
      expect(contourSegments(field(3, 3, List.filled(9, -60.0))), isEmpty);
    });

    test('a saddle gives two lines that do not cross', () {
      final f = field(2, 2, [-40, -80, -80, -40]);
      expect(contourSegments(f, step: 20).length / 4, 2);
    });

    test('none in empty areas, the faded edge or below the minimum', () {
      final values = [-60.0, -40, -60, -40, -60, -40];
      expect(contourSegments(field(2, 3, values)).length / 4, 6);
      expect(
        contourSegments(
              field(2, 3, values, coverage: [1, 1, 1, 1, 0, 0]),
            ).length /
            4,
        3,
      );
      expect(
        contourSegments(
              field(
                2,
                3,
                values,
                coverage: [1, 1, 1, 1, contourMinCoverage - 0.01, 1],
              ),
            ).length /
            4,
        3,
      );
      expect(contourSegments(field(2, 2, [-60, nan, -60, -40])), isEmpty);
      expect(contourSegments(field(2, 3, values), minRssi: -50), isEmpty);
    });

    test('drawContours darkens the pixels on the line only', () {
      final rgba = Uint8List(8 * 8 * 4);
      for (var i = 0; i < 64; i++) {
        rgba.setRange(i * 4, i * 4 + 4, const [200, 100, 50, 255]);
      }
      drawContours(
        rgba,
        8,
        8,
        Float32List.fromList([0.5, 4.5, 8, 4.5]),
        lineWidth: 1,
        alpha: 1,
      );
      // Row 4's centre is at y = 4.5: black. Row 0 is untouched.
      expect(rgba.sublist((4 * 8 + 3) * 4, (4 * 8 + 3) * 4 + 4), [
        0,
        0,
        0,
        255,
      ]);
      expect(rgba.sublist(0, 4), [200, 100, 50, 255]);
    });
  });

  group('whole picture', () {
    HeatGrid sample() => const HeatGrid(
      cols: 3,
      rows: 2,
      values: [-45, -60, null, -70, -85, -50],
      confidence: [1, 0.5, null, 1, 0.2, 1],
    );

    test('renderHeatPicture has contours only when asked', () {
      final plain = renderHeatPicture(
        HeatRequest(grid: sample(), contours: false),
      );
      final lined = renderHeatPicture(HeatRequest(grid: sample()));
      expect(plain.width, 5 * defaultUpsample);
      expect(plain.height, 4 * defaultUpsample);
      expect(plain.rgba, isNot(lined.rgba));
      // The cut-off removes pixels below it.
      final cut = renderHeatPicture(
        HeatRequest(grid: sample(), contours: false, minRssi: -60),
      );
      int visible(Uint8List b) {
        var n = 0;
        for (var i = 3; i < b.length; i += 4) {
          if (b[i] > 0) n++;
        }
        return n;
      }

      expect(visible(cut.rgba), lessThan(visible(plain.rgba)));
    });

    test('renderHeatPng makes a valid RGBA PNG of the same picture', () {
      final request = HeatRequest(grid: sample());
      final image = renderHeatPng(request);
      final picture = renderHeatPicture(request);
      final png = image.png;
      expect(png.sublist(0, 8), [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      final header = ByteData.sublistView(png, 8);
      expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
      expect(header.getUint32(8), image.width);
      expect(header.getUint32(12), image.height);
      expect(png[24], 8); // bit depth
      expect(png[25], 6); // RGBA
      expect((image.width, image.height), (picture.width, picture.height));
      expect(
        String.fromCharCodes(png.sublist(png.length - 8, png.length - 4)),
        'IEND',
      );
    });
  });

  group('png', () {
    test('rows round-trip through the zlib stream', () {
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 128, //
        0, 0, 255, 64, 1, 2, 3, 4,
      ]);
      final png = encodePng(rgba, 2, 2);
      // Find IDAT and inflate it.
      var offset = 8;
      Uint8List? idat;
      while (offset < png.length) {
        final length = ByteData.sublistView(png, offset).getUint32(0);
        final type = String.fromCharCodes(png.sublist(offset + 4, offset + 8));
        if (type == 'IDAT') {
          idat = png.sublist(offset + 8, offset + 8 + length);
        }
        offset += 12 + length;
      }
      final raw = Uint8List.fromList(ZLibDecoder().convert(idat!));
      expect(raw, [0, ...rgba.sublist(0, 8), 0, ...rgba.sublist(8)]);
    });
  });

  group('cells back into a grid', () {
    test('the grid, its size and its place come back from the squares', () {
      // Cells of 1e-5 degrees on a 3 x 2 lattice, one missing.
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.00001, 14.6, -60, 0, level: 'good', confidence: 0.5),
          cell(121.00002, 14.60001, -70, 0, level: 'fair'),
          cell(121.0, 14.60001, -80, 0, level: 'dead'),
        ]),
      );
      final heat = data.floorAt(0)!.heat!;
      expect((heat.grid.cols, heat.grid.rows), (3, 2));
      // Row 0 is the south row, column 0 the west column.
      expect(heat.grid.values, [-50, -60, null, -80, null, -70]);
      expect(heat.grid.confidence, [1, 0.5, null, 1, null, 1]);
      expect(heat.south, closeTo(14.6, 1e-9));
      expect(heat.west, closeTo(121.0, 1e-9));
      expect(heat.cellLat, closeTo(1e-5, 1e-9));
      expect(heat.cellLng, closeTo(1e-5, 1e-9));
    });

    test(
      'the picture is the grid plus a blank cell, so it is placed there',
      () {
        final heat = SurveyMapData.parse(
          geojson: collection([
            cell(121.0, 14.6, -50, 0, level: 'good'),
            cell(121.00001, 14.6, -60, 0, level: 'good'),
          ]),
        ).floorAt(0)!.heat!;
        final sw = heat.pictureSouthWest, ne = heat.pictureNorthEast;
        expect(sw.latitude, closeTo(14.6 - 1e-5, 1e-9));
        expect(sw.longitude, closeTo(121.0 - 1e-5, 1e-9));
        expect(ne.latitude, closeTo(14.6 + 2e-5, 1e-9));
        expect(ne.longitude, closeTo(121.0 + 3e-5, 1e-9));
      },
    );

    test('rounded GeoJSON corners (7 decimals) still land on the lattice', () {
      // 1 m is about 9e-6 degrees. The API rounds every corner to 7 decimals,
      // so each square is up to 1e-7 off: a lot, if the size were taken from
      // one square and multiplied up over 40 columns.
      double round7(double v) => double.parse(v.toStringAsFixed(7));
      final features = <Map<String, dynamic>>[];
      for (var i = 0; i < 40; i++) {
        final w0 = round7(121.0 + i * 0.000009),
            w1 = round7(121.0 + (i + 1) * 0.000009);
        final n0 = round7(14.6), n1 = round7(14.6 + 0.000009);
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [
              [
                [w0, n0],
                [w1, n0],
                [w1, n1],
                [w0, n1],
                [w0, n0],
              ],
            ],
          },
          'properties': {
            'kind': 'coverage',
            'rssi_dbm': -50.0 - i,
            'level': 'good',
            'floor_level': 0,
          },
        });
      }
      final heat = SurveyMapData.parse(
        geojson: collection(features),
      ).floorAt(0)!.heat!;
      expect(heat.grid.cols, 40);
      expect(heat.grid.rows, 1);
      expect(heat.grid.values, [for (var i = 0; i < 40; i++) -50.0 - i]);
    });

    test('nearestCell finds the cell, also from the blank border', () {
      final heat = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.00001, 14.6, -60, 0, level: 'good', confidence: 0.4),
          cell(121.00001, 14.60001, -90, 0, level: 'dead'),
        ]),
      ).floorAt(0)!.heat!;
      final west = heat.nearestCell(const LatLng(14.600005, 121.000005));
      expect((west.col, west.row, west.value), (0, 0, -50));
      final east = heat.nearestCell(const LatLng(14.600005, 121.000015));
      expect((east.col, east.row, east.value), (1, 0, -60));
      expect(east.confidence, closeTo(0.4, 1e-9));
      // The empty cell (north-west) reports no value.
      expect(
        heat.nearestCell(const LatLng(14.600015, 121.000005)).value,
        isNull,
      );
      // Far outside: clamped to the nearest cell.
      final far = heat.nearestCell(const LatLng(14.5, 120.0));
      expect((far.col, far.row), (0, 0));
    });

    test('no cells, or an absurd lattice, give no picture', () {
      expect(FloorHeat.fromCells(const []), isNull);
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(122.0, 15.6, -50, 0, level: 'good'),
        ]),
      );
      expect(data.floorAt(0)!.heat, isNull);
      expect(data.floorAt(0)!.cells, hasLength(2));
    });

    test('duplicate squares: the last one wins and nothing breaks', () {
      final heat = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.0, 14.6, -60, 0, level: 'good'),
        ]),
      ).floorAt(0)!.heat!;
      expect(heat.grid.values, [-60]);
    });
  });
}
