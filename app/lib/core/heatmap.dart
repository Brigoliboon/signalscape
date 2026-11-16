import 'dart:math' as math;
import 'dart:typed_data';

import 'levels.dart';
import 'png.dart';

// The smooth heatmap maths, shared by the 2D map and the live preview. It is
// plain Dart (no dart:ui), so it can run in an isolate and be tested directly.
// The 3D page has the same maths in api/app/static/viewer/heat.mjs; keep the
// ramp stops and the rules below in step with it.
//
// The API sends a plain grid (1 m cells, null = no data, confidence 0..1). The
// picture is made in three steps:
//   1. [upsampleGrid]: bilinear upsampling that never mixes in empty cells.
//   2. [renderHeatRgba]: dBm -> rainbow ramp, soft edge, confidence fade.
//   3. [contourSegments]: marching squares, a thin line every few dB.

/// One stop of the colour ramp.
class RampStop {
  const RampStop(this.dbm, this.r, this.g, this.b);
  final int dbm;
  final int r;
  final int g;
  final int b;
}

/// The colour ramp, strong to weak, like Acrylic Wi-Fi Heatmaps. Colours are
/// interpolated linearly in RGB between the stops and clamped outside them.
/// -67 dBm (green) is also the default "good" threshold.
const List<RampStop> rampStops = [
  RampStop(-30, 0xe3, 0x21, 0x1c), // red: very strong
  RampStop(-45, 0xf7, 0x86, 0x1e), // orange
  RampStop(-57, 0xfb, 0xe5, 0x1a), // yellow
  RampStop(-67, 0x38, 0xb5, 0x4a), // green
  RampStop(-78, 0x18, 0xc8, 0xdc), // cyan
  RampStop(-90, 0x2b, 0x5f, 0xd9), // blue
  RampStop(-100, 0x1b, 0x21, 0x66), // dark blue: nothing usable
];

const int rampStrongDbm = -30;
const int rampWeakDbm = -100;

/// Ticks on the legend bar.
const List<int> legendTicks = [-30, -45, -60, -75, -90, -100];

const int defaultContourStepDb = 5;
const int defaultUpsample = 6;
const int maxImageSide = 2048;

/// The picture has one blank cell all around the grid, so the edge can fade.
const int padCells = 1;

/// Contour lines are only drawn where the picture is at least this solid.
const double contourMinCoverage = 0.5;

/// [r, g, b] (0-255) of a signal strength in dBm, on the ramp.
List<int> rampColor(double dbm) {
  final first = rampStops.first;
  final last = rampStops.last;
  if (!(dbm < first.dbm)) return [first.r, first.g, first.b];
  if (dbm <= last.dbm) return [last.r, last.g, last.b];
  for (var i = 0; i < rampStops.length - 1; i++) {
    final hi = rampStops[i];
    final lo = rampStops[i + 1];
    if (dbm <= hi.dbm && dbm >= lo.dbm) {
      final t = (hi.dbm - dbm) / (hi.dbm - lo.dbm);
      int mix(int a, int b) => (a + (b - a) * t).round();
      return [mix(hi.r, lo.r), mix(hi.g, lo.g), mix(hi.b, lo.b)];
    }
  }
  return [last.r, last.g, last.b];
}

/// Position of a dBm value along the legend bar: 0 = strongest end, 1 = weakest.
double rampFraction(double dbm) =>
    ((rampStrongDbm - dbm) / (rampStrongDbm - rampWeakDbm)).clamp(0.0, 1.0);

double smoothstep(double x) {
  final t = x.clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

/// The upsampling factor actually used: as asked, but the picture stays
/// within [maxSide] pixels on its longest side.
int chooseFactor(
  int cols,
  int rows, {
  int requested = defaultUpsample,
  int maxSide = maxImageSide,
}) {
  final longest = math.max(cols, rows) + 2 * padCells;
  return math.max(1, math.min(requested, maxSide ~/ longest));
}

/// A grid of dBm values: row-major, row 0 = the south row, null = no data.
/// [confidence] (0..1 per cell) may be null, which means full confidence.
class HeatGrid {
  const HeatGrid({
    required this.cols,
    required this.rows,
    required this.values,
    this.confidence,
  });

  final int cols;
  final int rows;
  final List<double?> values;
  final List<double?>? confidence;

  double? at(int col, int row) => values[row * cols + col];
  double confidenceAt(int col, int row) =>
      confidenceOf(confidence?[row * cols + col]);
}

/// A grid turned into a picture (see [upsampleGrid]). Row 0 is the north row.
class HeatField {
  HeatField({
    required this.width,
    required this.height,
    required this.factor,
    required this.value,
    required this.coverage,
    required this.confidence,
  });

  final int width;
  final int height;
  final int factor;

  /// dBm at each pixel, NaN where nothing is near.
  final Float32List value;

  /// 0..1: the share of the four nearest cell centres that have data. It falls
  /// to 0 about one cell away from the data.
  final Float32List coverage;

  /// 0..1, from the confidence of the cells that count.
  final Float32List confidence;
}

/// Bilinear upsampling of [grid] into a picture that covers the grid plus one
/// blank cell on every side: (cols + 2) * factor wide, (rows + 2) * factor
/// tall. Empty cells are left out of the blend (weights are renormalised), so
/// colours never bleed into empty areas and the value never drifts towards
/// zero. The picture's soft edge comes from [HeatField.coverage].
HeatField upsampleGrid(
  HeatGrid grid, {
  int factor = defaultUpsample,
  int maxSide = maxImageSide,
}) {
  final cols = grid.cols, rows = grid.rows;
  final f = chooseFactor(cols, rows, requested: factor, maxSide: maxSide);
  final width = (cols + 2 * padCells) * f;
  final height = (rows + 2 * padCells) * f;
  final value = Float32List(width * height)
    ..fillRange(0, width * height, double.nan);
  final coverage = Float32List(width * height);
  final conf = Float32List(width * height);
  final raw = grid.values;
  for (var py = 0; py < height; py++) {
    final ys = (height - py - 0.5) / f - 0.5; // padded row index, south = 0
    final y0 = ys.floor();
    final ty = ys - y0;
    for (var px = 0; px < width; px++) {
      final xs = (px + 0.5) / f - 0.5;
      final x0 = xs.floor();
      final tx = xs - x0;
      var wsum = 0.0, vsum = 0.0, csum = 0.0;
      for (var dy = 0; dy < 2; dy++) {
        final row = y0 + dy - padCells;
        if (row < 0 || row >= rows) continue;
        final wy = dy == 0 ? 1 - ty : ty;
        for (var dx = 0; dx < 2; dx++) {
          final col = x0 + dx - padCells;
          if (col < 0 || col >= cols) continue;
          final index = row * cols + col;
          final v = raw[index];
          if (v == null || v.isNaN) continue;
          final w = wy * (dx == 0 ? 1 - tx : tx);
          wsum += w;
          vsum += w * v;
          csum += w * confidenceOf(grid.confidence?[index]);
        }
      }
      if (wsum > 1e-6) {
        final i = py * width + px;
        value[i] = vsum / wsum;
        coverage[i] = math.min(1.0, wsum);
        conf[i] = csum / wsum;
      }
    }
  }
  return HeatField(
    width: width,
    height: height,
    factor: f,
    value: value,
    coverage: coverage,
    confidence: conf,
  );
}

/// RGBA bytes of the picture (straight alpha). A pixel is transparent where
/// there is no data or the value is below [minRssi]. Elsewhere its colour is
/// the ramp colour of the value and its opacity is edge softness (coverage,
/// smoothed) x confidence fade x [opacity].
Uint8List renderHeatRgba(
  HeatField field, {
  double minRssi = -100,
  double opacity = 1,
}) {
  final out = Uint8List(field.width * field.height * 4);
  final total = field.width * field.height;
  for (var i = 0; i < total; i++) {
    final v = field.value[i];
    final cover = field.coverage[i];
    if (cover <= 0 || v.isNaN || v < minRssi) continue;
    final share =
        minConfidenceShare + (1 - minConfidenceShare) * field.confidence[i];
    final alpha = smoothstep(cover.toDouble()) * share * opacity;
    final c = rampColor(v);
    out[i * 4] = c[0];
    out[i * 4 + 1] = c[1];
    out[i * 4 + 2] = c[2];
    out[i * 4 + 3] = (255 * alpha.clamp(0.0, 1.0)).round();
  }
  return out;
}

// Marching squares. A cell has corners TL, TR, BR, BL (bits 0..3, set when the
// corner is at or above the level) and edges top=0, right=1, bottom=2,
// left=3. Each case lists the edge pairs a line joins; the two saddles are
// null and settled by the cell's average.
const List<List<List<int>>?> _segments = [
  [],
  [
    [3, 0],
  ],
  [
    [0, 1],
  ],
  [
    [3, 1],
  ],
  [
    [1, 2],
  ],
  null,
  [
    [0, 2],
  ],
  [
    [3, 2],
  ],
  [
    [2, 3],
  ],
  [
    [0, 2],
  ],
  null,
  [
    [1, 2],
  ],
  [
    [3, 1],
  ],
  [
    [0, 1],
  ],
  [
    [3, 0],
  ],
  [],
];

/// Contour lines of the picture at every [step] dB (multiples of the step, so
/// -50, -55 ...). Returns a flat list [x0, y0, x1, y1, ...] in pixel units,
/// y down, where pixel (i, j) has its centre at (i + 0.5, j + 0.5). Lines are
/// only made between pixels that have data, are at least
/// [contourMinCoverage] solid and are not below [minRssi], so there are none
/// in the fade-out or in empty areas.
Float32List contourSegments(
  HeatField field, {
  int step = defaultContourStepDb,
  double minRssi = -100,
}) {
  if (step <= 0) return Float32List(0);
  final width = field.width, height = field.height;
  final value = field.value, coverage = field.coverage;
  bool ok(int i) =>
      coverage[i] >= contourMinCoverage &&
      !value[i].isNaN &&
      value[i] >= minRssi;
  final out = <double>[];
  (double, double) point(
    int edge,
    int x,
    int y,
    double level,
    double vtl,
    double vtr,
    double vbr,
    double vbl,
  ) => switch (edge) {
    0 => (x + 0.5 + (level - vtl) / (vtr - vtl), y + 0.5),
    1 => (x + 1.5, y + 0.5 + (level - vtr) / (vbr - vtr)),
    2 => (x + 0.5 + (level - vbl) / (vbr - vbl), y + 1.5),
    _ => (x + 0.5, y + 0.5 + (level - vtl) / (vbl - vtl)),
  };
  for (var y = 0; y < height - 1; y++) {
    for (var x = 0; x < width - 1; x++) {
      final itl = y * width + x;
      final ibl = itl + width;
      if (!(ok(itl) && ok(itl + 1) && ok(ibl) && ok(ibl + 1))) continue;
      final vtl = value[itl].toDouble();
      final vtr = value[itl + 1].toDouble();
      final vbl = value[ibl].toDouble();
      final vbr = value[ibl + 1].toDouble();
      final lo = math.min(math.min(vtl, vtr), math.min(vbl, vbr));
      final hi = math.max(math.max(vtl, vtr), math.max(vbl, vbr));
      for (
        var level = (lo / step).ceil() * step.toDouble();
        level < hi;
        level += step
      ) {
        if (level <= lo) continue; // a level at the very bottom has no line
        final index =
            (vtl >= level ? 1 : 0) |
            (vtr >= level ? 2 : 0) |
            (vbr >= level ? 4 : 0) |
            (vbl >= level ? 8 : 0);
        var pairs = _segments[index];
        if (pairs == null) {
          final centreHigh = (vtl + vtr + vbr + vbl) / 4 >= level;
          pairs = index == 5
              ? (centreHigh
                    ? const [
                        [0, 1],
                        [3, 2],
                      ]
                    : const [
                        [3, 0],
                        [1, 2],
                      ])
              : (centreHigh
                    ? const [
                        [3, 0],
                        [1, 2],
                      ]
                    : const [
                        [0, 1],
                        [3, 2],
                      ]);
        }
        for (final pair in pairs) {
          final p = point(pair[0], x, y, level, vtl, vtr, vbr, vbl);
          final q = point(pair[1], x, y, level, vtl, vtr, vbr, vbl);
          out.addAll([p.$1, p.$2, q.$1, q.$2]);
        }
      }
    }
  }
  return Float32List.fromList(out);
}

/// Draws [segments] (see [contourSegments]) into [rgba] as thin dark lines,
/// about [lineWidth] pixels wide with soft edges, at [alpha] (0..1).
void drawContours(
  Uint8List rgba,
  int width,
  int height,
  Float32List segments, {
  double lineWidth = 1.2,
  double alpha = 0.8,
}) {
  final half = lineWidth / 2;
  for (var s = 0; s + 3 < segments.length; s += 4) {
    final x0 = segments[s], y0 = segments[s + 1];
    final x1 = segments[s + 2], y1 = segments[s + 3];
    final minX = math.max(0, (math.min(x0, x1) - half - 1).floor());
    final maxX = math.min(width - 1, (math.max(x0, x1) + half + 1).ceil());
    final minY = math.max(0, (math.min(y0, y1) - half - 1).floor());
    final maxY = math.min(height - 1, (math.max(y0, y1) + half + 1).ceil());
    final dx = x1 - x0, dy = y1 - y0;
    final len2 = dx * dx + dy * dy;
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final px = x + 0.5, py = y + 0.5;
        var t = len2 == 0 ? 0.0 : ((px - x0) * dx + (py - y0) * dy) / len2;
        t = t.clamp(0.0, 1.0);
        final cx = x0 + dx * t, cy = y0 + dy * t;
        final dist = math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
        final cover = (half + 0.5 - dist).clamp(0.0, 1.0);
        if (cover <= 0) continue;
        // Source-over of black at [alpha] x cover onto the pixel.
        final a = alpha * cover;
        final i = (y * width + x) * 4;
        final dstA = rgba[i + 3] / 255;
        final outA = a + dstA * (1 - a);
        if (outA <= 0) continue;
        for (var k = 0; k < 3; k++) {
          rgba[i + k] = (rgba[i + k] * dstA * (1 - a) / outA).round();
        }
        rgba[i + 3] = (outA * 255).round();
      }
    }
  }
}

/// What to draw: a grid and how.
class HeatRequest {
  const HeatRequest({
    required this.grid,
    this.minRssi = -100,
    this.contours = true,
    this.contourStepDb = defaultContourStepDb,
    this.upsample = defaultUpsample,
    this.maxSide = maxImageSide,
  });

  final HeatGrid grid;

  /// Values below this are transparent.
  final double minRssi;
  final bool contours;
  final int contourStepDb;
  final int upsample;
  final int maxSide;
}

/// A finished picture as PNG bytes. The picture covers [HeatGrid] plus
/// [padCells] blank cells on every side.
class HeatImage {
  const HeatImage({
    required this.png,
    required this.width,
    required this.height,
  });

  final Uint8List png;
  final int width;
  final int height;
}

/// Raw RGBA of the picture, contours included. Opacity is not applied: the
/// caller sets that on the widget so a slider does not redraw anything.
({Uint8List rgba, int width, int height}) renderHeatPicture(HeatRequest r) {
  final field = upsampleGrid(r.grid, factor: r.upsample, maxSide: r.maxSide);
  final rgba = renderHeatRgba(field, minRssi: r.minRssi);
  if (r.contours) {
    drawContours(
      rgba,
      field.width,
      field.height,
      contourSegments(field, step: r.contourStepDb, minRssi: r.minRssi),
      lineWidth: math.max(1.2, field.factor * 0.25),
    );
  }
  return (rgba: rgba, width: field.width, height: field.height);
}

/// [renderHeatPicture] encoded as a PNG. A top-level function so it can run
/// in an isolate with `compute`.
HeatImage renderHeatPng(HeatRequest request) {
  final p = renderHeatPicture(request);
  return HeatImage(
    png: encodePng(p.rgba, p.width, p.height),
    width: p.width,
    height: p.height,
  );
}

/// The cell nearest to a point given as fractions of the padded picture
/// (u west to east, v south to north, both 0..1). Points in the blank border
/// give the nearest cell.
({int col, int row}) cellAtPadded(double u, double v, int cols, int rows) => (
  col: ((u * (cols + 2 * padCells)).floor() - padCells).clamp(0, cols - 1),
  row: ((v * (rows + 2 * padCells)).floor() - padCells).clamp(0, rows - 1),
);
