import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'heatmap.dart';
import 'levels.dart';

/// One coverage cell: a square on the map with the signal level it was given.
class MapCell {
  const MapCell(this.ring, this.level, this.rssiDbm, [this.confidence = 1]);

  /// The corners, without the closing point.
  final List<LatLng> ring;
  final SignalLevel level;
  final double rssiDbm;

  /// 0 to 1, how well readings back the cell; 1 when the API sent none.
  final double confidence;
}

/// An estimated access point.
class MapAccessPoint {
  const MapAccessPoint({
    required this.at,
    required this.ssid,
    required this.bssid,
    required this.rssiDbm,
    required this.readingCount,
  });

  final LatLng at;
  final String ssid;
  final String bssid;

  /// The strongest reading the estimate was made from.
  final int rssiDbm;
  final int readingCount;

  String get name => ssid.isEmpty ? '(hidden network)' : ssid;
}

/// The cells of one floor put back into a grid, with where it sits on the map,
/// so the heatmap can be drawn as one smooth picture. The API's GeoJSON has one
/// square per cell with data; their corners sit on a regular lattice (the
/// grid), so the grid is found again from the squares.
class FloorHeat {
  const FloorHeat({
    required this.grid,
    required this.south,
    required this.west,
    required this.cellLat,
    required this.cellLng,
  });

  /// Rebuilds the grid from [cells], or null when there is nothing to draw (no
  /// cells, a degenerate cell, or a lattice so large it must be bad data).
  static FloorHeat? fromCells(List<MapCell> cells, {int maxCells = 4000000}) {
    if (cells.isEmpty) return null;
    double? south, west, north, east;
    for (final c in cells) {
      for (final p in c.ring) {
        south = south == null || p.latitude < south ? p.latitude : south;
        north = north == null || p.latitude > north ? p.latitude : north;
        west = west == null || p.longitude < west ? p.longitude : west;
        east = east == null || p.longitude > east ? p.longitude : east;
      }
    }
    // The size of one cell. Corners are rounded in the GeoJSON, so one cell's
    // box is only roughly right: use the average over all cells to count the
    // columns and rows, then take the exact size from the whole extent.
    var sumLat = 0.0, sumLng = 0.0;
    for (final c in cells) {
      final lats = c.ring.map((p) => p.latitude);
      final lngs = c.ring.map((p) => p.longitude);
      sumLat += lats.reduce(math.max) - lats.reduce(math.min);
      sumLng += lngs.reduce(math.max) - lngs.reduce(math.min);
    }
    final roughLat = sumLat / cells.length;
    final roughLng = sumLng / cells.length;
    if (roughLat <= 0 || roughLng <= 0) return null;
    final cols = ((east! - west!) / roughLng).round();
    final rows = ((north! - south!) / roughLat).round();
    if (cols < 1 || rows < 1 || cols * rows > maxCells) return null;
    final cellLat = (north - south) / rows;
    final cellLng = (east - west) / cols;
    final values = List<double?>.filled(cols * rows, null);
    final confidence = List<double?>.filled(cols * rows, null);
    for (final c in cells) {
      final minLat = c.ring.map((p) => p.latitude).reduce(math.min);
      final minLng = c.ring.map((p) => p.longitude).reduce(math.min);
      final col = ((minLng - west) / cellLng).round();
      final row = ((minLat - south) / cellLat).round();
      if (col < 0 || col >= cols || row < 0 || row >= rows) continue;
      values[row * cols + col] = c.rssiDbm;
      confidence[row * cols + col] = c.confidence;
    }
    return FloorHeat(
      grid: HeatGrid(
        cols: cols,
        rows: rows,
        values: values,
        confidence: confidence,
      ),
      south: south,
      west: west,
      cellLat: cellLat,
      cellLng: cellLng,
    );
  }

  final HeatGrid grid;

  /// The south-west corner of the grid, in degrees.
  final double south;
  final double west;

  /// The size of one cell, in degrees.
  final double cellLat;
  final double cellLng;

  /// The corners of the picture: the grid plus one blank cell on every side.
  LatLng get pictureSouthWest =>
      LatLng(south - padCells * cellLat, west - padCells * cellLng);
  LatLng get pictureNorthEast => LatLng(
    south + (grid.rows + padCells) * cellLat,
    west + (grid.cols + padCells) * cellLng,
  );

  /// The cell nearest to [at] (a tap just outside the data still finds the
  /// nearest one), with its value, or null value when that cell is empty.
  ({int col, int row, double? value, double confidence}) nearestCell(
    LatLng at,
  ) {
    final u =
        (at.longitude - pictureSouthWest.longitude) /
        ((grid.cols + 2 * padCells) * cellLng);
    final v =
        (at.latitude - pictureSouthWest.latitude) /
        ((grid.rows + 2 * padCells) * cellLat);
    final c = cellAtPadded(u, v, grid.cols, grid.rows);
    return (
      col: c.col,
      row: c.row,
      value: grid.at(c.col, c.row),
      confidence: grid.confidenceAt(c.col, c.row),
    );
  }
}

/// Everything drawn for one floor. Only one floor is shown at a time.
class FloorLayer {
  const FloorLayer({
    required this.level,
    required this.label,
    this.cells = const [],
    this.accessPoints = const [],
    this.trail = const [],
    this.start,
    this.end,
    this.heat,
  });

  final int level;
  final String label;
  final List<MapCell> cells;

  /// The cells as one grid for the smooth picture, null when there are none.
  final FloorHeat? heat;
  final List<MapAccessPoint> accessPoints;

  /// The walk on this floor, in time order.
  final List<LatLng> trail;
  final LatLng? start;
  final LatLng? end;

  bool get isEmpty =>
      cells.isEmpty && accessPoints.isEmpty && trail.isEmpty && start == null;
}

/// A survey's results as the 2D map shows them (FR-16a): one layer per floor,
/// read from the API's GeoJSON, trail and summary.
class SurveyMapData {
  const SurveyMapData(this.floors, {this.thresholds});

  /// Reads the three answers. [geojson] is the FeatureCollection from
  /// `/geojson`; [trail] from `/trail` and [summary] from `/summary` are
  /// optional (the map still works without a trail or floor names). Features
  /// that cannot be read are skipped rather than failing the whole map.
  factory SurveyMapData.parse({
    required Map<String, dynamic> geojson,
    Map<String, dynamic>? trail,
    Map<String, dynamic>? summary,
    Thresholds fallback = const Thresholds(),
  }) {
    final labels = <int, String>{};
    Thresholds? found;
    final floorList = summary?['floors'];
    if (floorList is List) {
      for (final f in floorList) {
        if (f is Map && f['floor_level'] is num && f['floor_label'] is String) {
          labels[(f['floor_level'] as num).toInt()] =
              f['floor_label'] as String;
        }
        final t = f is Map ? f['thresholds'] : null;
        if (found == null &&
            t is Map &&
            t['good_dbm'] is num &&
            t['dead_dbm'] is num) {
          found = Thresholds(
            goodDbm: (t['good_dbm'] as num).toInt(),
            deadDbm: (t['dead_dbm'] as num).toInt(),
          );
        }
      }
    }
    final cells = <int, List<MapCell>>{};
    final aps = <int, List<MapAccessPoint>>{};
    final features = geojson['features'];
    if (features is List) {
      for (final f in features) {
        if (f is! Map) continue;
        final props = f['properties'];
        final geometry = f['geometry'];
        if (props is! Map || geometry is! Map || props['floor_level'] is! num) {
          continue;
        }
        final level = (props['floor_level'] as num).toInt();
        switch (props['kind']) {
          case 'coverage':
            final cell = _cell(geometry, props, found ?? fallback);
            if (cell != null) cells.putIfAbsent(level, () => []).add(cell);
          case 'access_point':
            final ap = _accessPoint(geometry, props);
            if (ap != null) aps.putIfAbsent(level, () => []).add(ap);
        }
      }
    }

    final trails = <int, List<LatLng>>{};
    final trailFloors = trail?['floors'];
    if (trailFloors is List) {
      for (final f in trailFloors) {
        if (f is! Map || f['floor_level'] is! num || f['points'] is! List) {
          continue;
        }
        final points = <LatLng>[
          for (final p in f['points'] as List)
            ?_latLng(p is Map ? p['lat'] : null, p is Map ? p['lng'] : null),
        ];
        trails[(f['floor_level'] as num).toInt()] = points;
      }
    }
    final start = _trailEnd(trail?['start']);
    final end = _trailEnd(trail?['end']);

    // Floors of the summary stay in the list even when this network has
    // nothing on them, so the floor selector does not jump around.
    final levels = {
      ...labels.keys,
      ...cells.keys,
      ...aps.keys,
      ...trails.keys,
      ?start?.$1,
      ?end?.$1,
    }.toList()..sort((a, b) => b.compareTo(a));
    return SurveyMapData([
      for (final l in levels)
        FloorLayer(
          level: l,
          label: labels[l] ?? 'Level $l',
          cells: cells[l] ?? const [],
          heat: FloorHeat.fromCells(cells[l] ?? const []),
          accessPoints: aps[l] ?? const [],
          trail: trails[l] ?? const [],
          start: start != null && start.$1 == l ? start.$2 : null,
          end: end != null && end.$1 == l ? end.$2 : null,
        ),
    ], thresholds: found);
  }

  /// Floors with something to show, top floor first.
  final List<FloorLayer> floors;

  /// The surveyor's thresholds, when the summary had them.
  final Thresholds? thresholds;

  bool get isEmpty => floors.every((f) => f.isEmpty);

  /// The floor to open on: the one with the most coverage, else the first.
  FloorLayer? get initialFloor {
    if (floors.isEmpty) return null;
    var best = floors.first;
    for (final f in floors) {
      if (f.cells.length > best.cells.length) best = f;
    }
    return best;
  }

  /// The floor with this level, or null.
  FloorLayer? floorAt(int level) {
    for (final f in floors) {
      if (f.level == level) return f;
    }
    return null;
  }
}

/// A box around [floor]'s data, or null when it has none.
({LatLng sw, LatLng ne})? boundsOf(FloorLayer floor) {
  double? minLat, maxLat, minLng, maxLng;
  void add(LatLng p) {
    minLat = minLat == null || p.latitude < minLat! ? p.latitude : minLat;
    maxLat = maxLat == null || p.latitude > maxLat! ? p.latitude : maxLat;
    minLng = minLng == null || p.longitude < minLng! ? p.longitude : minLng;
    maxLng = maxLng == null || p.longitude > maxLng! ? p.longitude : maxLng;
  }

  for (final c in floor.cells) {
    c.ring.forEach(add);
  }
  floor.accessPoints.map((a) => a.at).forEach(add);
  floor.trail.forEach(add);
  if (floor.start != null) add(floor.start!);
  if (floor.end != null) add(floor.end!);
  if (minLat == null) return null;
  return (sw: LatLng(minLat!, minLng!), ne: LatLng(maxLat!, maxLng!));
}

LatLng? _latLng(Object? lat, Object? lng) {
  if (lat is! num || lng is! num) return null;
  final la = lat.toDouble(), lo = lng.toDouble();
  if (la < -90 || la > 90 || lo < -180 || lo > 180) return null;
  return LatLng(la, lo);
}

/// GeoJSON positions are `[lng, lat]`.
LatLng? _position(Object? p) =>
    p is List && p.length >= 2 ? _latLng(p[1], p[0]) : null;

MapCell? _cell(Map geometry, Map props, Thresholds t) {
  if (geometry['type'] != 'Polygon') return null;
  final rings = geometry['coordinates'];
  if (rings is! List || rings.isEmpty || rings.first is! List) return null;
  final ring = <LatLng>[for (final p in rings.first as List) ?_position(p)];
  // GeoJSON rings repeat the first corner at the end.
  if (ring.length > 1 && ring.first == ring.last) ring.removeLast();
  if (ring.length < 3) return null;
  final rssi = props['rssi_dbm'];
  if (rssi is! num) return null;
  final level = switch (props['level']) {
    'good' => SignalLevel.good,
    'fair' => SignalLevel.fair,
    'dead' => SignalLevel.dead,
    _ => levelFor(rssi, t),
  };
  return MapCell(
    ring,
    level,
    rssi.toDouble(),
    confidenceOf(props['confidence']),
  );
}

MapAccessPoint? _accessPoint(Map geometry, Map props) {
  if (geometry['type'] != 'Point') return null;
  final at = _position(geometry['coordinates']);
  final bssid = props['bssid'];
  final rssi = props['rssi_dbm'];
  if (at == null || bssid is! String || rssi is! num) return null;
  return MapAccessPoint(
    at: at,
    ssid: props['ssid'] is String ? props['ssid'] as String : '',
    bssid: bssid,
    rssiDbm: rssi.toInt(),
    readingCount: (props['reading_count'] as num?)?.toInt() ?? 0,
  );
}

(int, LatLng)? _trailEnd(Object? p) {
  if (p is! Map || p['floor_level'] is! num) return null;
  final at = _latLng(p['lat'], p['lng']);
  return at == null ? null : ((p['floor_level'] as num).toInt(), at);
}

/// A Wi-Fi network (one BSSID) the survey saw, for the network picker.
class MapNetwork {
  const MapNetwork({
    required this.ssid,
    required this.bssid,
    required this.readingCount,
  });

  final String ssid;
  final String bssid;
  final int readingCount;

  String get name => ssid.isEmpty ? '(hidden network)' : ssid;

  /// "Name · aa:bb:…", as the 3D view's picker shows it.
  String get label => '$name · $bssid';
}

/// Networks from `/networks`, one entry per BSSID, in the order given (most
/// readings first). A BSSID seen under several SSIDs counts once.
List<MapNetwork> parseNetworks(List<Map<String, dynamic>> items) {
  final seen = <String>{};
  final out = <MapNetwork>[];
  for (final n in items) {
    final bssid = n['bssid'];
    if (bssid is! String || !seen.add(bssid)) continue;
    out.add(
      MapNetwork(
        ssid: n['ssid'] is String ? n['ssid'] as String : '',
        bssid: bssid,
        readingCount: (n['reading_count'] as num?)?.toInt() ?? 0,
      ),
    );
  }
  return out;
}
