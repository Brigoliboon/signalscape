import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/levels.dart';
import 'package:signalscape_mobile/core/router_data.dart';

const double cellDeg = 0.000009;

/// A grid in the API's layout (south row first).
Map<String, dynamic> gridJson(
  List<double?> values, {
  int cols = 3,
  double lat = 14.6,
  double lng = 121.0,
}) {
  final rows = values.length ~/ cols;
  return {
    'origin_lat': lat,
    'origin_lng': lng,
    'north_lat': lat + rows * cellDeg,
    'east_lng': lng + cols * cellDeg,
    'cell_size_m': 1.0,
    'cols': cols,
    'rows': rows,
    'values': values,
  };
}

Map<String, dynamic> routerJson(
  int number, {
  String? id,
  List<String> ssids = const ['staff'],
  double? lat = 14.6,
  double? lng = 121.0,
  bool? low = false,
  List<double?> footprint = const [-50, -70, -90],
}) => {
  'router_id': id ?? 'r$number',
  'number': number,
  'label': 'Router $number',
  'ssids': ssids,
  'networks': [
    for (final (i, s) in ssids.indexed)
      {
        'bssid': 'aa:bb:cc:dd:ee:$number$i',
        'ssid': s,
        'frequency_mhz': 2437,
        'reading_count': 10,
        'max_rssi_dbm': -40 - i,
      },
  ],
  'max_rssi_dbm': -40,
  'lat': lat,
  'lng': lng,
  'confidence': low == null ? null : 0.8,
  'low_confidence': low,
  'area_m2': 2.0,
  'good_area_m2': 1.0,
  'footprint': gridJson(footprint),
};

Map<String, dynamic> extendedRouterJson(
  int number, {
  String? id,
  String role = 'extender',
  double? lat = 14.6,
  double? lng = 121.0,
  bool determined = true,
  bool? low = false,
  int rssi = -40,
}) => {
  'router_id': id ?? 'r$number',
  'number': number,
  'label': 'Router $number',
  'role': role,
  'max_rssi_dbm': rssi,
  'lat': determined ? lat : null,
  'lng': determined ? lng : null,
  'confidence': low == null ? null : 0.8,
  'low_confidence': low,
  'position_determined': determined,
};

Map<String, dynamic> staffNetwork({
  List<Map<String, dynamic>>? routers,
  List<Map<String, dynamic>>? links,
  bool includeGaps = true,
}) => {
  'ssid': 'staff',
  'router_ids': ['r1', 'r2'],
  'router_count': 2,
  'likely_main': 'r1',
  'floors': [
    {
      'floor_id': 'f0',
      'floor_level': 0,
      'floor_label': 'Ground',
      'likely_main': 'r1',
      'routers':
          routers ??
          [
            extendedRouterJson(1, role: 'likely_main', rssi: -35),
            extendedRouterJson(
              2,
              lat: 14.6,
              lng: 121.0001,
              low: true,
              rssi: -50,
            ),
          ],
      'links':
          links ??
          [
            {
              'from_router': 'r1',
              'to_router': 'r2',
              'length_m': 10.4,
              'min_rssi_dbm': -91.2,
              'weak_m': 2.0,
              'dead_m': 4.2,
              'no_data_m': 0.0,
              'status': 'dead',
            },
          ],
      'weak_cells': 2,
      'dead_cells': 4,
      'gap_area_m2': 6.0,
      'gaps': includeGaps ? gridJson([null, -70, -90]) : null,
      'coverage': gridJson([-50, -70, -90]),
    },
  ],
};

Map<String, dynamic> coverageJson({
  List<Map<String, dynamic>>? routers,
  List<Map<String, dynamic>>? chains,
  List<Map<String, dynamic>>? extendedNetworks,
  String heuristic =
      'The likely main router is the one with the strongest reading of that network name.',
}) => {
  'survey_id': 's1',
  'thresholds': {'good_dbm': -60, 'dead_dbm': -75},
  'router_count': 3,
  'bssid_count': 4,
  'grouping': 'BSSIDs with the same first five bytes ...',
  'gap_corridor_m': 3.0,
  'main_heuristic': heuristic,
  'extended_networks': extendedNetworks ?? [staffNetwork()],
  'floors': [
    {
      'floor_id': 'f1',
      'floor_level': 1,
      'floor_label': 'Upper',
      'router_count': 1,
      'routers': [
        routerJson(3, ssids: ['lab']),
      ],
      'chains': <Object>[],
    },
    {
      'floor_id': 'f0',
      'floor_level': 0,
      'floor_label': 'Ground',
      'router_count': 2,
      'routers':
          routers ??
          [
            routerJson(1, ssids: ['guest', 'staff']),
            routerJson(2, lat: 14.6, lng: 121.0001, low: true),
          ],
      'chains':
          chains ??
          [
            {
              'ssids': ['staff'],
              'router_ids': ['r1', 'r2'],
              'links': [
                {
                  'from_router': 'r1',
                  'to_router': 'r2',
                  'length_m': 10.4,
                  'min_rssi_dbm': -91.2,
                  'weak_m': 2.0,
                  'dead_m': 4.2,
                  'no_data_m': 0.0,
                  'status': 'dead',
                },
              ],
              'weak_cells': 2,
              'dead_cells': 4,
              'gap_area_m2': 6.0,
              'gaps': gridJson([null, -70, -90]),
            },
          ],
    },
  ],
};

void main() {
  test('parses routers, chains and floors in level order', () {
    final data = RouterCoverage.parse(coverageJson());
    expect(data.thresholds, const Thresholds(goodDbm: -60, deadDbm: -75));
    expect(data.routerCount, 3);
    expect(data.bssidCount, 4);
    expect(data.floors.map((f) => f.level), [0, 1]);
    final ground = data.floorAt(0)!;
    expect(ground.label, 'Ground');
    final main = ground.routers.first;
    expect(main.label, 'Router 1');
    expect(main.ssids, ['guest', 'staff']);
    expect(main.ssidText, 'guest, staff');
    expect(main.networks, hasLength(2));
    expect(main.lowConfidence, isFalse);
    expect(main.summaryText, '2 networks · 2 BSSIDs · 2 m² covered');
    expect(main.footprint!.grid.cols, 3);
    expect(main.footprint!.cellLat, closeTo(cellDeg, 1e-12));
    expect(ground.routers[1].lowConfidence, isTrue);
    final chain = ground.chains.single;
    expect(chain.name, 'staff');
    expect(chain.routerIds, ['r1', 'r2']);
    expect(chain.links.single.status, 'dead');
    expect(chain.gaps!.grid.values, [null, -70, -90]);
    expect(data.extendedNetworks, hasLength(1));
    final staff = data.extendedNetworks.single;
    expect(staff.ssid, 'staff');
    expect(staff.likelyMain, 'r1');
    expect(staff.floors.single.routers.first.role, RouterRole.likelyMain);
    expect(staff.floors.single.routers.last.role, RouterRole.extender);
    expect(staff.floors.single.coverage, isNotNull);
    expect(data.mainHeuristic, contains('strongest reading'));
    expect(ground.routerById('r2')!.number, 2);
    expect(ground.routerById('nope'), isNull);
    expect(data.floorAt(5), isNull);
    expect(data.isEmpty, isFalse);
  });

  test('a router not placed here and one with no rating', () {
    final data = RouterCoverage.parse(
      coverageJson(
        routers: [
          routerJson(1, lat: null, lng: null, ssids: ['']),
          routerJson(2, low: null),
        ],
        chains: [],
      ),
    );
    final routers = data.floorAt(0)!.routers;
    expect(routers[0].at, isNull);
    expect(routers[0].ssidText, '(hidden network)');
    expect(routers[0].summaryText, endsWith('not placed on this floor'));
    expect(routers[1].lowConfidence, isTrue);
  });

  test('an undetermined extended router has no pin', () {
    final data = RouterCoverage.parse(
      coverageJson(
        extendedNetworks: [
          staffNetwork(
            routers: [
              extendedRouterJson(1, role: 'likely_main', rssi: -35),
              extendedRouterJson(2, determined: false, rssi: -78),
            ],
            links: [],
            includeGaps: false,
          ),
        ],
      ),
    );
    final routers = data.extendedNetworks.single.floors.single.routers;
    expect(routers.last.positionDetermined, isFalse);
    expect(routers.last.at, isNull);
    expect(routers.last.positionText, 'Position not determined');
  });

  test('unreadable parts are skipped', () {
    final data = RouterCoverage.parse({
      'floors': [
        'x',
        {
          'floor_level': 0,
          'routers': [
            {'number': 1},
            {
              'router_id': 'r1',
              'number': 1,
              'footprint': {
                'cols': 2,
                'rows': 1,
                'values': [-50],
              },
              'networks': [
                {'ssid': 'no bssid'},
              ],
            },
          ],
          'chains': [
            'x',
            {
              'links': [
                {'from_router': 'r1'},
              ],
            },
          ],
        },
      ],
    });
    expect(data.thresholds, const Thresholds());
    final floor = data.floors.single;
    expect(floor.label, 'Level 0');
    expect(floor.routers.single.footprint, isNull);
    expect(floor.routers.single.networks, isEmpty);
    expect(floor.chains.single.links, isEmpty);
    expect(RouterCoverage.parse({}).isEmpty, isTrue);
    expect(gridHeat(gridJson([-50, -60, -70])..['north_lat'] = 1.0), isNull);
  });

  test('router colours are not signal colours and repeat', () {
    const signal = {0x22C55E, 0xFBBF24, 0xFB7185};
    for (final rgb in routerPalette) {
      expect(signal.contains(rgb), isFalse);
    }
    expect(routerRgb(1), 0x1D4ED8);
    expect(routerRgb(1 + routerPalette.length), routerRgb(1));
    expect(routerRgb(0), routerRgb(1));
  });

  test('link text says where the gap is', () {
    const dead = RouterLink(
      from: 'r1',
      to: 'r2',
      lengthM: 10.4,
      status: 'dead',
      minRssiDbm: -91.2,
      deadM: 4.2,
    );
    expect(
      linkText(dead, 'Router 1', 'Router 2'),
      'Router 1 → Router 2 · 10 m · dead gap 4 m (weakest -91 dBm)',
    );
    const weak = RouterLink(
      from: 'a',
      to: 'b',
      lengthM: 5,
      status: 'weak',
      weakM: 1.6,
    );
    expect(linkText(weak, 'A', 'B'), 'A → B · 5 m · weak gap 2 m');
    const ok = RouterLink(
      from: 'a',
      to: 'b',
      lengthM: 5,
      status: 'covered',
      minRssiDbm: -55,
    );
    expect(
      linkText(ok, 'A', 'B'),
      'A → B · 5 m · covered all the way (weakest -55 dBm)',
    );
    const none = RouterLink(from: 'a', to: 'b', lengthM: 5, status: 'no_data');
    expect(linkText(none, 'A', 'B'), 'A → B · 5 m · not walked, no data');
  });

  test('footprint picture: good stronger than fair, dead and empty clear', () {
    final heat = gridHeat(gridJson([-50, -70, -90, null], cols: 4))!;
    const t = Thresholds(goodDbm: -60, deadDbm: -75);
    final p = footprintRgba(heat.grid, 0x7C3AED, t, pixelsPerCell: 2);
    // 4 cells plus a blank one on each side, 2 pixels each.
    expect(p.width, 12);
    expect(p.height, 6);
    int alpha(int px, int py) => p.rgba[(py * p.width + px) * 4 + 3];
    expect(alpha(2, 2), (footprintGoodAlpha * 255).round());
    expect(alpha(4, 2), (footprintFairAlpha * 255).round());
    expect(alpha(6, 2), 0);
    expect(alpha(8, 2), 0);
    expect(alpha(0, 0), 0);
    expect(p.rgba.sublist((2 * p.width + 2) * 4, (2 * p.width + 2) * 4 + 3), [
      0x7C,
      0x3A,
      0xED,
    ]);
    expect(renderFootprintPng(heat.grid, 0x7C3AED, t), isNotNull);
    final none = gridHeat(gridJson([-90, null, -95]))!;
    expect(renderFootprintPng(none.grid, 0x7C3AED, t), isNull);
  });
}
