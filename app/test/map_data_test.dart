import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:signalscape_mobile/core/levels.dart';
import 'package:signalscape_mobile/core/map_data.dart';
import 'package:signalscape_mobile/theme.dart';

Map<String, dynamic> cell(
  double lng,
  double lat,
  double rssi,
  int floor, {
  String? level,
  Object? confidence,
}) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [lng, lat],
        [lng + 0.00001, lat],
        [lng + 0.00001, lat + 0.00001],
        [lng, lat + 0.00001],
        [lng, lat],
      ],
    ],
  },
  'properties': {
    'kind': 'coverage',
    'rssi_dbm': rssi,
    'level': ?level,
    'confidence': ?confidence,
    'floor_level': floor,
    'bssid': null,
  },
};

Map<String, dynamic> ap(
  double lng,
  double lat,
  int floor, {
  String ssid = 'Lab',
  String bssid = 'aa:bb:cc:dd:ee:01',
  int readings = 7,
  double? confidence,
  bool? lowConfidence,
  double? spreadM,
}) => {
  'type': 'Feature',
  'geometry': {
    'type': 'Point',
    'coordinates': [lng, lat],
  },
  'properties': {
    'kind': 'access_point',
    'ssid': ssid,
    'bssid': bssid,
    'floor_level': floor,
    'rssi_dbm': -48,
    'reading_count': readings,
    'confidence': ?confidence,
    'low_confidence': ?lowConfidence,
    'spread_m': ?spreadM,
  },
};

Map<String, dynamic> collection(List<Map<String, dynamic>> f) => {
  'type': 'FeatureCollection',
  'features': f,
};

Map<String, dynamic> summary() => {
  'floors': [
    {
      'floor_level': 0,
      'floor_label': 'Ground',
      'thresholds': {'good_dbm': -60, 'dead_dbm': -75},
    },
    {'floor_level': 1, 'floor_label': 'First', 'thresholds': null},
  ],
};

Map<String, dynamic> trailJson() => {
  'start': {'floor_level': 0, 'lat': 14.6, 'lng': 121.0, 'kind': 'start'},
  'end': {'floor_level': 1, 'lat': 14.6003, 'lng': 121.0003, 'kind': 'reading'},
  'floors': [
    {
      'floor_level': 0,
      'points': [
        {'lat': 14.6, 'lng': 121.0, 'kind': 'start'},
        {'lat': 14.6001, 'lng': 121.0001, 'kind': 'reading'},
        {'lat': 'bad', 'lng': 121.0, 'kind': 'reading'},
      ],
    },
    {
      'floor_level': 1,
      'points': [
        {'lat': 14.6003, 'lng': 121.0003, 'kind': 'reading'},
      ],
    },
  ],
};

void main() {
  group('GeoJSON parsing', () {
    test('cells become one closed-ring-free square per feature, by floor', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.00001, 14.6, -70, 0, level: 'fair'),
          cell(121.0, 14.6, -90, 1, level: 'dead'),
        ]),
      );
      expect(data.floors.map((f) => f.level), [1, 0]); // top floor first
      final ground = data.floorAt(0)!;
      expect(ground.cells, hasLength(2));
      expect(ground.cells.first.ring, hasLength(4));
      // GeoJSON is [lng, lat].
      expect(ground.cells.first.ring.first, const LatLng(14.6, 121.0));
      expect(data.floorAt(1)!.cells.single.level, SignalLevel.dead);
      expect(data.floorAt(7), isNull);
    });

    test('cells carry their confidence, and none means 1', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good', confidence: 0.4),
          cell(121.0, 14.6, -60, 0, level: 'good'),
          cell(121.0, 14.6, -70, 0, level: 'fair', confidence: 'high'),
          cell(121.0, 14.6, -72, 0, level: 'fair', confidence: 3),
        ]),
      );
      final conf = data.floorAt(0)!.cells.map((c) => c.confidence).toList();
      expect(conf, [0.4, 1.0, 1.0, 1.0]);
    });

    test('the API level wins, and a missing level is worked out', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.0, 14.6, -99, 0, level: 'good'), // API says good: keep
          cell(121.0, 14.6, -50, 0),
          cell(121.0, 14.6, -72, 0),
          cell(121.0, 14.6, -95, 0),
        ]),
      );
      final levels = data.floorAt(0)!.cells.map((c) => c.level).toList();
      expect(levels, [
        SignalLevel.good,
        SignalLevel.good,
        SignalLevel.good,
        SignalLevel.fair,
        SignalLevel.dead,
      ]);
    });

    test('the missing level uses the surveyor thresholds from the summary', () {
      final data = SurveyMapData.parse(
        geojson: collection([cell(121.0, 14.6, -65, 0)]),
        summary: summary(),
      );
      expect(data.thresholds, const Thresholds(goodDbm: -60, deadDbm: -75));
      expect(data.floorAt(0)!.cells.single.level, SignalLevel.fair);
    });

    test('colours follow the app level colours', () {
      expect(levelColor(SignalLevel.good), AppColors.good);
      expect(levelColor(SignalLevel.fair), AppColors.fair);
      expect(levelColor(SignalLevel.dead), AppColors.dead);
    });

    test('access points keep their SSID, BSSID and strongest reading', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          ap(121.0002, 14.6002, 0),
          ap(121.0, 14.6, 0, ssid: ''),
        ]),
      );
      final aps = data.floorAt(0)!.accessPoints;
      expect(aps, hasLength(2));
      expect(aps.first.ssid, 'Lab');
      expect(aps.first.bssid, 'aa:bb:cc:dd:ee:01');
      expect(aps.first.rssiDbm, -48);
      expect(aps.first.readingCount, 7);
      expect(aps.first.at, const LatLng(14.6002, 121.0002));
      expect(aps.last.name, '(hidden network)');
    });

    test('access points keep their placement confidence (FR-25)', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          ap(
            121.0,
            14.6,
            0,
            readings: 12,
            confidence: 0.87,
            lowConfidence: false,
            spreadM: 6.42,
          ),
          ap(
            121.0001,
            14.6,
            0,
            bssid: 'aa:bb:cc:dd:ee:02',
            readings: 3,
            confidence: 0.12,
            lowConfidence: true,
            spreadM: 1.25,
          ),
          // processed before v1.1: no rating, so it counts as low confidence
          ap(121.0002, 14.6, 0, bssid: 'aa:bb:cc:dd:ee:03', readings: 1),
        ]),
      );
      final aps = data.floorAt(0)!.accessPoints;
      expect(aps[0].confidence, 0.87);
      expect(aps[0].lowConfidence, isFalse);
      expect(aps[0].spreadM, 6.42);
      expect(
        aps[0].confidenceText,
        'Confidence 87%: 12 readings · spread 6.4 m',
      );
      expect(aps[1].lowConfidence, isTrue);
      expect(
        aps[1].confidenceText,
        'Low confidence: 3 readings · spread 1.3 m · 12%',
      );
      expect(aps[2].confidence, isNull);
      expect(aps[2].lowConfidence, isTrue);
      expect(
        aps[2].confidenceText,
        'Low confidence: 1 reading · not rated, process the survey again',
      );
    });

    test('features that cannot be read are skipped', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          {'type': 'Feature'},
          {'type': 'Feature', 'geometry': null, 'properties': {}},
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [1, 2],
            },
            'properties': {'kind': 'reading', 'floor_level': 0},
          },
          {
            'type': 'Feature',
            'geometry': {'type': 'Polygon', 'coordinates': []},
            'properties': {
              'kind': 'coverage',
              'floor_level': 0,
              'rssi_dbm': -50,
            },
          },
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [121.0, 14.6],
                  [121.0, 14.6],
                ],
              ],
            },
            'properties': {
              'kind': 'coverage',
              'floor_level': 0,
              'rssi_dbm': -50,
            },
          },
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [121.0, 14.6],
            },
            'properties': {'kind': 'access_point', 'floor_level': 0},
          },
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [999, 14.6],
            },
            'properties': {
              'kind': 'access_point',
              'floor_level': 0,
              'bssid': 'x',
              'rssi_dbm': -50,
            },
          },
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [121.0, 14.6],
                ],
              ],
            },
            'properties': {'kind': 'coverage', 'floor_level': 0},
          },
        ]),
      );
      expect(data.floorAt(0)!.cells, hasLength(1));
      expect(data.floorAt(0)!.accessPoints, isEmpty);
    });

    test('nothing at all is empty', () {
      expect(SurveyMapData.parse(geojson: collection([])).isEmpty, isTrue);
      expect(SurveyMapData.parse(geojson: {}).floors, isEmpty);
      expect(SurveyMapData.parse(geojson: {}).initialFloor, isNull);
    });
  });

  group('floors', () {
    test('labels come from the summary, else "Level n"', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.0, 14.6, -50, 2, level: 'good'),
        ]),
        summary: summary(),
      );
      expect(data.floorAt(0)!.label, 'Ground');
      expect(data.floorAt(2)!.label, 'Level 2');
    });

    test('only one floor\'s data is in a floor layer', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          ap(121.0, 14.6, 1),
        ]),
        trail: trailJson(),
      );
      expect(data.floorAt(0)!.accessPoints, isEmpty);
      expect(data.floorAt(1)!.cells, isEmpty);
      expect(data.floorAt(1)!.accessPoints, hasLength(1));
    });

    test('opens on the floor with the most coverage', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          cell(121.0, 14.6, -50, 1, level: 'good'),
          cell(121.0, 14.6, -50, 1, level: 'good'),
        ]),
      );
      expect(data.initialFloor!.level, 1);
    });
  });

  group('trail', () {
    test('points, start and end land on their own floors', () {
      final data = SurveyMapData.parse(
        geojson: collection([cell(121.0, 14.6, -50, 0, level: 'good')]),
        trail: trailJson(),
      );
      final ground = data.floorAt(0)!;
      expect(ground.trail, hasLength(2)); // the bad point is dropped
      expect(ground.start, const LatLng(14.6, 121.0));
      expect(ground.end, isNull);
      final first = data.floorAt(1)!;
      expect(first.start, isNull);
      expect(first.end, const LatLng(14.6003, 121.0003));
      expect(first.trail, hasLength(1));
    });

    test('a map with a trail but no coverage still has floors', () {
      final data = SurveyMapData.parse(
        geojson: collection([]),
        trail: trailJson(),
      );
      expect(data.isEmpty, isFalse);
      expect(data.floors.map((f) => f.level), [1, 0]);
    });

    test('a malformed trail is ignored', () {
      final data = SurveyMapData.parse(
        geojson: collection([cell(121.0, 14.6, -50, 0, level: 'good')]),
        trail: {
          'start': {'floor_level': 'x'},
          'end': {'floor_level': 0, 'lat': null, 'lng': 1},
          'floors': [
            'nope',
            {'floor_level': 0},
            {'floor_level': 0, 'points': 'x'},
          ],
        },
      );
      expect(data.floorAt(0)!.trail, isEmpty);
      expect(data.floorAt(0)!.start, isNull);
    });
  });

  group('bounds', () {
    test('cover cells, access points, trail and the ends', () {
      final data = SurveyMapData.parse(
        geojson: collection([
          cell(121.0, 14.6, -50, 0, level: 'good'),
          ap(121.001, 14.601, 0),
        ]),
        trail: trailJson(),
      );
      final b = boundsOf(data.floorAt(0)!)!;
      expect(b.sw.latitude, closeTo(14.6, 1e-9));
      expect(b.sw.longitude, closeTo(121.0, 1e-9));
      expect(b.ne.latitude, closeTo(14.601, 1e-9));
      expect(b.ne.longitude, closeTo(121.001, 1e-9));
    });

    test('an end point counts, and an empty floor has none', () {
      final data = SurveyMapData.parse(geojson: {}, trail: trailJson());
      final b = boundsOf(data.floorAt(1)!)!;
      expect(b.sw, const LatLng(14.6003, 121.0003));
      expect(b.ne, b.sw);
      expect(boundsOf(const FloorLayer(level: 5, label: 'x')), isNull);
      expect(const FloorLayer(level: 5, label: 'x').isEmpty, isTrue);
    });
  });

  group('networks and floors', () {
    test('networks are listed once per BSSID, in order', () {
      final nets = parseNetworks([
        {'ssid': 'Lab', 'bssid': 'a1', 'reading_count': 9},
        {'ssid': '', 'bssid': 'a2', 'reading_count': 4},
        {'ssid': 'Other', 'bssid': 'a1', 'reading_count': 2},
        {'ssid': 'x'},
        {'bssid': 'a3', 'ssid': 5},
      ]);
      expect(nets.map((n) => n.bssid), ['a1', 'a2', 'a3']);
      expect(nets[0].label, 'Lab · a1');
      expect(nets[0].readingCount, 9);
      expect(nets[1].name, '(hidden network)');
      expect(nets[2].ssid, '');
      expect(nets[2].readingCount, 0);
    });

    test('floors of the summary stay when a network has nothing on them', () {
      final data = SurveyMapData.parse(
        geojson: collection([cell(121.0, 14.6, -50, 0, level: 'good')]),
        summary: summary(),
      );
      expect(data.floors.map((f) => f.level), [1, 0]);
      expect(data.floorAt(1)!.isEmpty, isTrue);
      expect(data.isEmpty, isFalse);
      // ... but nothing anywhere is still empty.
      expect(
        SurveyMapData.parse(
          geojson: collection([]),
          summary: summary(),
        ).isEmpty,
        isTrue,
      );
    });
  });
}
