import 'dart:math' as math;
import 'dart:typed_data';

import 'heatmap.dart';
import 'levels.dart';
import 'png.dart';

// The dead and weak zone layer (FR-26): every cell classified as dead or fair
// (weak) with the FR-15 thresholds, drawn as flat shading over the map. Weak is
// amber, dead is red with a diagonal hatch, so the two differ without colour.
// The 3D page draws the same layer in api/app/static/viewer/levels.mjs
// (zonePixels); keep the colours and the hatch in step with it.

/// Opacity of the zone shading.
const double zoneAlpha = 0.35;

/// Opacity of the hatch lines on dead zones.
const double zoneHatchAlpha = 0.85;

/// Hatch lines repeat every this many pixels and are this many pixels wide.
const int zoneHatchPeriod = 6;
const int zoneHatchWidth = 2;

/// Pixels per cell, at most; big grids use fewer so the picture stays small.
const int zonePixelsPerCell = 8;

/// Amber for weak (fair) zones and red for dead ones, as 0xRRGGBB.
const int zoneWeakRgb = 0xFBBF24; // AppColors.fair
const int zoneDeadRgb = 0xFB7185; // AppColors.dead

/// The legend text of each zone, from the thresholds in force.
String weakZoneText(Thresholds t) => 'Weak: ${t.deadDbm} to ${t.goodDbm} dBm';
String deadZoneText(Thresholds t) => 'Dead: below ${t.deadDbm} dBm';

/// Whether a picture pixel in a dead zone is on a hatch line (lines run from
/// bottom left to top right).
bool onHatch(int px, int py) => (px + py) % zoneHatchPeriod < zoneHatchWidth;

/// The zone picture of [grid]: RGBA, row 0 = north, with [padCells] blank cells
/// on every side so it covers the same bounds as the heatmap picture.
({Uint8List rgba, int width, int height}) zonesRgba(
  HeatGrid grid,
  Thresholds t, {
  int maxSide = maxImageSide,
}) {
  final longest = math.max(grid.cols, grid.rows) + 2 * padCells;
  final scale = math.max(1, math.min(zonePixelsPerCell, maxSide ~/ longest));
  final width = (grid.cols + 2 * padCells) * scale;
  final height = (grid.rows + 2 * padCells) * scale;
  final out = Uint8List(width * height * 4);
  final weakA = (zoneAlpha * 255).round();
  final hatchA = (zoneHatchAlpha * 255).round();
  for (var py = 0; py < height; py++) {
    final row = (height - 1 - py) ~/ scale - padCells; // south = 0
    if (row < 0 || row >= grid.rows) continue;
    for (var px = 0; px < width; px++) {
      final col = px ~/ scale - padCells;
      if (col < 0 || col >= grid.cols) continue;
      final value = grid.at(col, row);
      if (value == null) continue;
      final level = levelFor(value, t);
      if (level == SignalLevel.good) continue;
      final dead = level == SignalLevel.dead;
      final rgb = dead ? zoneDeadRgb : zoneWeakRgb;
      final i = (py * width + px) * 4;
      out[i] = (rgb >> 16) & 0xff;
      out[i + 1] = (rgb >> 8) & 0xff;
      out[i + 2] = rgb & 0xff;
      out[i + 3] = dead && onHatch(px, py) ? hatchA : weakA;
    }
  }
  return (rgba: out, width: width, height: height);
}

/// [zonesRgba] as a PNG for the map, or null when no cell is weak or dead.
HeatImage? renderZonesPng(HeatGrid grid, Thresholds t) {
  final p = zonesRgba(grid, t);
  var any = false;
  for (var i = 3; i < p.rgba.length; i += 4) {
    if (p.rgba[i] != 0) {
      any = true;
      break;
    }
  }
  if (!any) return null;
  return HeatImage(
    png: encodePng(p.rgba, p.width, p.height),
    width: p.width,
    height: p.height,
  );
}
