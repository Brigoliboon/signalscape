import 'package:latlong2/latlong.dart';

import 'levels.dart';

/// One coverage cell: a square on the map with the signal level it was given.
class MapCell {
  const MapCell(this.ring, this.level, this.rssiDbm);

  /// The corners, without the closing point.
  final List<LatLng> ring;
  final SignalLevel level;
  final double rssiDbm;
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
  });

  final int level;
  final String label;
  final List<MapCell> cells;
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

    final levels = {
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
  return MapCell(ring, level, rssi.toDouble());
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
