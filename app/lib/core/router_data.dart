import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import 'heatmap.dart';
import 'levels.dart';
import 'map_data.dart';
import 'png.dart';

// Router coverage mode (FR-27 to FR-29): read from GET /surveys/{id}/routers.
// The mode opens on extended networks (a named SSID served by two or more
// routers). Reach is the heatmap of that network; per-router footprints are
// not the default view. Router identity colours are blues and purples, never
// the green, amber or red of signal levels, which stay for the weak and dead
// gaps. The 3D page uses the same palette (ROUTER_PALETTE in levels.mjs).

/// Router identity colours as 0xRRGGBB, by router number (1 = first).
const List<int> routerPalette = [
  0x1D4ED8, // blue (AppColors.primary)
  0xC026D3, // fuchsia
  0x0891B2, // cyan
  0x4F46E5, // indigo
  0x0284C7, // sky
  0x475569, // slate
  0x1E3A8A, // navy
  0x6B21A8, // deep purple
];

int routerRgb(int number) =>
    routerPalette[(math.max(1, number) - 1) % routerPalette.length];

/// Footprint opacity where the router's signal is good, and where it is only
/// fair (weak). Below the dead threshold the router does not cover the cell.
const double footprintGoodAlpha = 0.45;
const double footprintFairAlpha = 0.22;

/// One BSSID of a router and the network name it broadcasts.
class RouterNetwork {
  const RouterNetwork({
    required this.bssid,
    required this.ssid,
    required this.readings,
    required this.maxRssiDbm,
  });

  final String bssid;
  final String ssid;
  final int readings;
  final int maxRssiDbm;

  String get name => ssid.isEmpty ? '(hidden network)' : ssid;
}

/// A router on one floor (FR-27, FR-28).
class MapRouter {
  const MapRouter({
    required this.id,
    required this.number,
    required this.label,
    required this.ssids,
    required this.networks,
    required this.maxRssiDbm,
    required this.areaM2,
    required this.goodAreaM2,
    this.at,
    this.lowConfidence = true,
    this.footprint,
  });

  final String id;
  final int number;
  final String label;
  final List<String> ssids;
  final List<RouterNetwork> networks;
  final int maxRssiDbm;
  final double areaM2;
  final double goodAreaM2;

  /// Its estimated position, when it is placed on this floor.
  final LatLng? at;
  final bool lowConfidence;
  final FloorHeat? footprint;

  int get rgb => routerRgb(number);

  /// "staff, guest" with hidden names spelled out.
  String get ssidText => ssids.isEmpty
      ? '(hidden network)'
      : ssids.map((s) => s.isEmpty ? '(hidden network)' : s).join(', ');

  /// One line for the router list.
  String get summaryText {
    final names = ssids.length == 1 ? '1 network' : '${ssids.length} networks';
    final bssids = networks.map((n) => n.bssid).toSet().length;
    final b = bssids == 1 ? '1 BSSID' : '$bssids BSSIDs';
    return '$names · $b · ${areaM2.round()} m² covered'
        '${at == null ? ' · not placed on this floor' : ''}';
  }
}

/// A straight link between two routers of a chain.
class RouterLink {
  const RouterLink({
    required this.from,
    required this.to,
    required this.lengthM,
    required this.status,
    this.minRssiDbm,
    this.weakM = 0,
    this.deadM = 0,
    this.noDataM = 0,
  });

  final String from;
  final String to;
  final double lengthM;
  final double? minRssiDbm;
  final double weakM;
  final double deadM;
  final double noDataM;

  /// covered, weak, dead or no_data.
  final String status;
}

/// Routers on one floor that share a network name (FR-29).
class RouterChain {
  const RouterChain({
    required this.ssids,
    required this.routerIds,
    required this.links,
    required this.weakCells,
    required this.deadCells,
    required this.gapAreaM2,
    this.gaps,
  });

  final List<String> ssids;
  final List<String> routerIds;
  final List<RouterLink> links;
  final int weakCells;
  final int deadCells;
  final double gapAreaM2;

  /// The chain's best signal on its gap cells only, null without a gap.
  final FloorHeat? gaps;

  String get name => ssids.map((s) => s.isEmpty ? '(hidden)' : s).join(', ');
}

class RouterFloor {
  const RouterFloor({
    required this.level,
    required this.label,
    required this.routers,
    required this.chains,
  });

  final int level;
  final String label;
  final List<MapRouter> routers;
  final List<RouterChain> chains;

  MapRouter? routerById(String id) {
    for (final r in routers) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// "likely_main" or "extender". The label is an estimate, never a fact.
enum RouterRole { likelyMain, extender }

/// One router of an extended network, on one floor.
class ExtendedRouter {
  const ExtendedRouter({
    required this.id,
    required this.number,
    required this.label,
    required this.role,
    required this.maxRssiDbm,
    this.at,
    this.lowConfidence = true,
    this.positionDetermined = false,
  });

  final String id;
  final int number;
  final String label;
  final RouterRole role;
  final int maxRssiDbm;
  final LatLng? at;
  final bool lowConfidence;
  final bool positionDetermined;

  int get rgb => routerRgb(number);

  /// Shown in the list and the details sheet.
  String get roleText =>
      role == RouterRole.likelyMain ? 'Likely main' : 'Extender';

  String get positionText =>
      positionDetermined ? roleText : MapAccessPoint.positionNotDeterminedText;
}

/// One floor of an extended network.
class ExtendedNetworkFloor {
  const ExtendedNetworkFloor({
    required this.level,
    required this.label,
    required this.likelyMain,
    required this.routers,
    required this.links,
    required this.weakCells,
    required this.deadCells,
    required this.gapAreaM2,
    this.gaps,
    this.coverage,
  });

  final int level;
  final String label;
  final String? likelyMain;
  final List<ExtendedRouter> routers;
  final List<RouterLink> links;
  final int weakCells;
  final int deadCells;
  final double gapAreaM2;
  final FloorHeat? gaps;
  final FloorHeat? coverage;

  ExtendedRouter? routerById(String id) {
    for (final r in routers) {
      if (r.id == id) return r;
    }
    return null;
  }
}

/// A named SSID served by two or more routers.
class ExtendedNetwork {
  const ExtendedNetwork({
    required this.ssid,
    required this.routerIds,
    required this.routerCount,
    this.likelyMain,
    required this.floors,
  });

  final String ssid;
  final List<String> routerIds;
  final int routerCount;
  final String? likelyMain;
  final List<ExtendedNetworkFloor> floors;

  String get name => ssid.isEmpty ? '(hidden network)' : ssid;

  ExtendedNetworkFloor? floorAt(int level) {
    for (final f in floors) {
      if (f.level == level) return f;
    }
    return null;
  }
}

class RouterCoverage {
  const RouterCoverage({
    required this.thresholds,
    required this.routerCount,
    required this.bssidCount,
    required this.floors,
    this.grouping = '',
    this.mainHeuristic = '',
    this.extendedNetworks = const [],
  });

  final Thresholds thresholds;
  final int routerCount;
  final int bssidCount;
  final String grouping;
  final String mainHeuristic;
  final List<RouterFloor> floors;
  final List<ExtendedNetwork> extendedNetworks;

  ExtendedNetwork? networkNamed(String ssid) {
    for (final n in extendedNetworks) {
      if (n.ssid == ssid) return n;
    }
    return null;
  }

  bool get isEmpty => floors.every((f) => f.routers.isEmpty);

  RouterFloor? floorAt(int level) {
    for (final f in floors) {
      if (f.level == level) return f;
    }
    return null;
  }

  /// Unreadable parts are skipped rather than failing the whole mode.
  factory RouterCoverage.parse(Map<String, dynamic> json) {
    final t = json['thresholds'];
    final thresholds = t is Map && t['good_dbm'] is num && t['dead_dbm'] is num
        ? Thresholds(
            goodDbm: (t['good_dbm'] as num).toInt(),
            deadDbm: (t['dead_dbm'] as num).toInt(),
          )
        : const Thresholds();
    final floors = <RouterFloor>[];
    for (final f in _list(json['floors'])) {
      if (f is! Map || f['floor_level'] is! num) continue;
      final routers = <MapRouter>[];
      for (final r in _list(f['routers'])) {
        final router = _router(r);
        if (router != null) routers.add(router);
      }
      final chains = <RouterChain>[];
      for (final c in _list(f['chains'])) {
        final chain = _chain(c);
        if (chain != null) chains.add(chain);
      }
      floors.add(
        RouterFloor(
          level: (f['floor_level'] as num).toInt(),
          label: f['floor_label'] is String
              ? f['floor_label'] as String
              : 'Level ${f['floor_level']}',
          routers: routers,
          chains: chains,
        ),
      );
    }
    floors.sort((a, b) => a.level.compareTo(b.level));
    final extended = <ExtendedNetwork>[];
    for (final n in _list(json['extended_networks'])) {
      final network = _extendedNetwork(n);
      if (network != null) extended.add(network);
    }
    return RouterCoverage(
      thresholds: thresholds,
      routerCount: _int(json['router_count']),
      bssidCount: _int(json['bssid_count']),
      grouping: json['grouping'] is String ? json['grouping'] as String : '',
      mainHeuristic: json['main_heuristic'] is String
          ? json['main_heuristic'] as String
          : '',
      floors: floors,
      extendedNetworks: extended,
    );
  }
}

List<Object?> _list(Object? raw) => raw is List ? raw : const [];
int _int(Object? raw) => raw is num ? raw.toInt() : 0;
double _double(Object? raw) => raw is num ? raw.toDouble() : 0;

MapRouter? _router(Object? r) {
  if (r is! Map || r['router_id'] is! String || r['number'] is! num) {
    return null;
  }
  final networks = <RouterNetwork>[];
  for (final n in _list(r['networks'])) {
    if (n is! Map || n['bssid'] is! String) continue;
    networks.add(
      RouterNetwork(
        bssid: n['bssid'] as String,
        ssid: n['ssid'] is String ? n['ssid'] as String : '',
        readings: _int(n['reading_count']),
        maxRssiDbm: _int(n['max_rssi_dbm']),
      ),
    );
  }
  final lat = r['lat'], lng = r['lng'];
  LatLng? at;
  if (lat is num && lng is num && lat.abs() <= 90 && lng.abs() <= 180) {
    at = LatLng(lat.toDouble(), lng.toDouble());
  }
  final number = (r['number'] as num).toInt();
  return MapRouter(
    id: r['router_id'] as String,
    number: number,
    label: r['label'] is String ? r['label'] as String : 'Router $number',
    ssids: [
      for (final s in _list(r['ssids']))
        if (s is String) s,
    ],
    networks: networks,
    maxRssiDbm: _int(r['max_rssi_dbm']),
    areaM2: _double(r['area_m2']),
    goodAreaM2: _double(r['good_area_m2']),
    at: at,
    // No rating (older results): drawn as low confidence, as on the map.
    lowConfidence: r['low_confidence'] != false,
    footprint: gridHeat(r['footprint']),
  );
}

RouterChain? _chain(Object? c) {
  if (c is! Map) return null;
  final links = <RouterLink>[];
  for (final l in _list(c['links'])) {
    if (l is! Map || l['from_router'] is! String || l['to_router'] is! String) {
      continue;
    }
    links.add(
      RouterLink(
        from: l['from_router'] as String,
        to: l['to_router'] as String,
        lengthM: _double(l['length_m']),
        minRssiDbm: l['min_rssi_dbm'] is num
            ? (l['min_rssi_dbm'] as num).toDouble()
            : null,
        weakM: _double(l['weak_m']),
        deadM: _double(l['dead_m']),
        noDataM: _double(l['no_data_m']),
        status: l['status'] is String ? l['status'] as String : 'no_data',
      ),
    );
  }
  return RouterChain(
    ssids: [
      for (final s in _list(c['ssids']))
        if (s is String) s,
    ],
    routerIds: [
      for (final s in _list(c['router_ids']))
        if (s is String) s,
    ],
    links: links,
    weakCells: _int(c['weak_cells']),
    deadCells: _int(c['dead_cells']),
    gapAreaM2: _double(c['gap_area_m2']),
    gaps: gridHeat(c['gaps']),
  );
}

ExtendedNetwork? _extendedNetwork(Object? raw) {
  if (raw is! Map || raw['ssid'] is! String) return null;
  final floors = <ExtendedNetworkFloor>[];
  for (final f in _list(raw['floors'])) {
    if (f is! Map || f['floor_level'] is! num) continue;
    final routers = <ExtendedRouter>[];
    for (final r in _list(f['routers'])) {
      final router = _extendedRouter(r);
      if (router != null) routers.add(router);
    }
    final links = <RouterLink>[];
    for (final l in _list(f['links'])) {
      if (l is! Map ||
          l['from_router'] is! String ||
          l['to_router'] is! String) {
        continue;
      }
      links.add(
        RouterLink(
          from: l['from_router'] as String,
          to: l['to_router'] as String,
          lengthM: _double(l['length_m']),
          minRssiDbm: l['min_rssi_dbm'] is num
              ? (l['min_rssi_dbm'] as num).toDouble()
              : null,
          weakM: _double(l['weak_m']),
          deadM: _double(l['dead_m']),
          noDataM: _double(l['no_data_m']),
          status: l['status'] is String ? l['status'] as String : 'no_data',
        ),
      );
    }
    floors.add(
      ExtendedNetworkFloor(
        level: (f['floor_level'] as num).toInt(),
        label: f['floor_label'] is String
            ? f['floor_label'] as String
            : 'Level ${f['floor_level']}',
        likelyMain: f['likely_main'] is String
            ? f['likely_main'] as String
            : null,
        routers: routers,
        links: links,
        weakCells: _int(f['weak_cells']),
        deadCells: _int(f['dead_cells']),
        gapAreaM2: _double(f['gap_area_m2']),
        gaps: gridHeat(f['gaps']),
        coverage: gridHeat(f['coverage']),
      ),
    );
  }
  floors.sort((a, b) => a.level.compareTo(b.level));
  return ExtendedNetwork(
    ssid: raw['ssid'] as String,
    routerIds: [
      for (final s in _list(raw['router_ids']))
        if (s is String) s,
    ],
    routerCount: _int(raw['router_count']),
    likelyMain: raw['likely_main'] is String
        ? raw['likely_main'] as String
        : null,
    floors: floors,
  );
}

ExtendedRouter? _extendedRouter(Object? r) {
  if (r is! Map || r['router_id'] is! String || r['number'] is! num) {
    return null;
  }
  final lat = r['lat'], lng = r['lng'];
  LatLng? at;
  final determined = r['position_determined'] == true;
  if (determined &&
      lat is num &&
      lng is num &&
      lat.abs() <= 90 &&
      lng.abs() <= 180) {
    at = LatLng(lat.toDouble(), lng.toDouble());
  }
  final number = (r['number'] as num).toInt();
  return ExtendedRouter(
    id: r['router_id'] as String,
    number: number,
    label: r['label'] is String ? r['label'] as String : 'Router $number',
    role: r['role'] == 'likely_main'
        ? RouterRole.likelyMain
        : RouterRole.extender,
    maxRssiDbm: _int(r['max_rssi_dbm']),
    at: at,
    lowConfidence: r['low_confidence'] != false,
    positionDetermined: determined && at != null,
  );
}

/// A grid of the API (origin and north-east corner, cols, rows, values) as a
/// [FloorHeat], or null when it is missing or does not add up.
FloorHeat? gridHeat(Object? raw, {int maxCells = 4000000}) {
  if (raw is! Map) return null;
  final cols = raw['cols'], rows = raw['rows'], values = raw['values'];
  final south = raw['origin_lat'], west = raw['origin_lng'];
  final north = raw['north_lat'], east = raw['east_lng'];
  if (cols is! num ||
      rows is! num ||
      values is! List ||
      south is! num ||
      west is! num ||
      north is! num ||
      east is! num) {
    return null;
  }
  final c = cols.toInt(), r = rows.toInt();
  if (c < 1 || r < 1 || c * r > maxCells || values.length != c * r) {
    return null;
  }
  if (!(north > south) || !(east > west)) return null;
  return FloorHeat(
    grid: HeatGrid(
      cols: c,
      rows: r,
      values: [for (final v in values) v is num ? v.toDouble() : null],
    ),
    south: south.toDouble(),
    west: west.toDouble(),
    cellLat: (north - south) / r,
    cellLng: (east - west) / c,
  );
}

/// What a link means, for the chain list: "Router 1 → Router 2 · 12 m · dead
/// gap 4 m (weakest -91 dBm)".
String linkText(RouterLink link, String fromLabel, String toLabel) {
  final head = '$fromLabel → $toLabel · ${link.lengthM.round()} m';
  final weakest = link.minRssiDbm == null
      ? ''
      : ' (weakest ${link.minRssiDbm!.round()} dBm)';
  return switch (link.status) {
    'dead' => '$head · dead gap ${link.deadM.round()} m$weakest',
    'weak' => '$head · weak gap ${link.weakM.round()} m$weakest',
    'covered' => '$head · covered all the way$weakest',
    _ => '$head · not walked, no data',
  };
}

/// The footprint picture of [heat] in [rgb]: good cells at
/// [footprintGoodAlpha], fair ones at [footprintFairAlpha], dead and empty
/// cells clear. Row 0 is north, with [padCells] blank cells on every side so
/// it covers the bounds of [FloorHeat.pictureSouthWest] and NorthEast.
({Uint8List rgba, int width, int height}) footprintRgba(
  HeatGrid grid,
  int rgb,
  Thresholds t, {
  int maxSide = maxImageSide,
  int pixelsPerCell = 4,
}) {
  final longest = math.max(grid.cols, grid.rows) + 2 * padCells;
  final scale = math.max(1, math.min(pixelsPerCell, maxSide ~/ longest));
  final width = (grid.cols + 2 * padCells) * scale;
  final height = (grid.rows + 2 * padCells) * scale;
  final out = Uint8List(width * height * 4);
  final goodA = (footprintGoodAlpha * 255).round();
  final fairA = (footprintFairAlpha * 255).round();
  for (var py = 0; py < height; py++) {
    final row = (height - 1 - py) ~/ scale - padCells;
    if (row < 0 || row >= grid.rows) continue;
    for (var px = 0; px < width; px++) {
      final col = px ~/ scale - padCells;
      if (col < 0 || col >= grid.cols) continue;
      final value = grid.at(col, row);
      if (value == null) continue;
      final level = levelFor(value, t);
      if (level == SignalLevel.dead) continue;
      final i = (py * width + px) * 4;
      out[i] = (rgb >> 16) & 0xff;
      out[i + 1] = (rgb >> 8) & 0xff;
      out[i + 2] = rgb & 0xff;
      out[i + 3] = level == SignalLevel.good ? goodA : fairA;
    }
  }
  return (rgba: out, width: width, height: height);
}

/// [footprintRgba] as a PNG, or null when the router covers no cell.
HeatImage? renderFootprintPng(HeatGrid grid, int rgb, Thresholds t) {
  final p = footprintRgba(grid, rgb, t);
  for (var i = 3; i < p.rgba.length; i += 4) {
    if (p.rgba[i] != 0) {
      return HeatImage(
        png: encodePng(p.rgba, p.width, p.height),
        width: p.width,
        height: p.height,
      );
    }
  }
  return null;
}
