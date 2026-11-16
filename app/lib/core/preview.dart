import 'geo.dart';
import 'levels.dart';

/// The live preview heatmap (FR-11a): the API's strongest-signal grid for one
/// floor, placed in the same metres-from-origin frame as the live trail.
///
/// Values are dBm, row-major, south row first and west column first; null
/// means no data. [x0] and [y0] are the south-west corner in metres.
class PreviewGrid {
  const PreviewGrid({
    required this.floorId,
    required this.cellM,
    required this.cols,
    required this.rows,
    required this.x0,
    required this.y0,
    required this.values,
    required this.computedAt,
    this.confidence,
  });

  /// Reads one `CoverageRead` from the API. [originLat] and [originLng] are
  /// the survey's start point. Returns null for a grid that cannot be drawn.
  static PreviewGrid? fromJson(
    Map<String, dynamic> j, {
    required double originLat,
    required double originLng,
    DateTime? computedAt,
  }) {
    final cols = (j['cols'] as num?)?.toInt() ?? 0;
    final rows = (j['rows'] as num?)?.toInt() ?? 0;
    final cell = (j['cell_size_m'] as num?)?.toDouble() ?? 0;
    final raw = j['values'];
    if (cols <= 0 || rows <= 0 || cell <= 0 || raw is! List) return null;
    if (raw.length != cols * rows) return null;
    final sw = toLocal(
      (j['origin_lat'] as num).toDouble(),
      (j['origin_lng'] as num).toDouble(),
      originLat,
      originLng,
    );
    return PreviewGrid(
      floorId: j['floor_id'] as String,
      cellM: cell,
      cols: cols,
      rows: rows,
      x0: sw.x,
      y0: sw.y,
      values: [for (final v in raw) (v as num?)?.toDouble()],
      computedAt: computedAt ?? DateTime.now(),
      confidence: switch (j['confidence']) {
        final List c when c.length == cols * rows => [
          for (final v in c) v == null ? null : confidenceOf(v),
        ],
        _ => null,
      },
    );
  }

  final String floorId;
  final double cellM;
  final int cols;
  final int rows;
  final double x0;
  final double y0;
  final List<double?> values;
  final DateTime computedAt;

  /// 0 to 1 per cell (see `confidenceOf`), or null when the API sent none.
  final List<double?>? confidence;

  double get x1 => x0 + cols * cellM;
  double get y1 => y0 + rows * cellM;

  /// Value of the cell at [col], [row], or null when empty.
  double? at(int col, int row) => values[row * cols + col];

  /// Confidence of the cell at [col], [row]; 1 when unknown.
  double confidenceAt(int col, int row) => confidence?[row * cols + col] ?? 1.0;

  int get filledCells => values.where((v) => v != null).length;
}

/// Picks the grid to draw for [floorId] from a preview response's `grids`:
/// the strongest-signal grid (no BSSID) of that floor.
PreviewGrid? pickPreviewGrid(
  Map<String, dynamic> response,
  String floorId, {
  required double originLat,
  required double originLng,
}) {
  final grids = response['grids'];
  if (grids is! List) return null;
  final computed = DateTime.tryParse('${response['computed_at']}')?.toLocal();
  for (final g in grids) {
    if (g is! Map<String, dynamic>) continue;
    if (g['floor_id'] != floorId || g['bssid'] != null) continue;
    return PreviewGrid.fromJson(
      g,
      originLat: originLat,
      originLng: originLng,
      computedAt: computed,
    );
  }
  return null;
}
