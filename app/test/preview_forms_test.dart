import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/core/forms.dart';
import 'package:signalscape_mobile/core/geo.dart';
import 'package:signalscape_mobile/core/plan_image.dart';
import 'package:signalscape_mobile/core/preview.dart';

Map<String, dynamic> grid({
  String floorId = 'f1',
  String? bssid,
  int cols = 2,
  int rows = 2,
  List<dynamic>? values,
}) => {
  'floor_id': floorId,
  'bssid': bssid,
  'cell_size_m': 2.0,
  'origin_lat': 14.0,
  'origin_lng': 121.0,
  'cols': cols,
  'rows': rows,
  'values': values ?? [-50, null, -70, -85],
};

void main() {
  group('PreviewGrid', () {
    test('places the south-west corner in the trail frame', () {
      final g = PreviewGrid.fromJson(
        grid(),
        originLat: 14.0,
        originLng: 121.0,
      )!;
      expect(g.x0, closeTo(0, 1e-6));
      expect(g.y0, closeTo(0, 1e-6));
      expect(g.x1, closeTo(4, 1e-6));
      expect(g.y1, closeTo(4, 1e-6));
      expect(g.filledCells, 3);
      expect(g.at(0, 0), -50);
      expect(g.at(1, 0), isNull); // east of the first cell, south row
      expect(g.at(0, 1), -70); // second row, further north
    });

    test('the corner is offset when the survey origin is elsewhere', () {
      final geo = toGeo(10, 20, 14.0, 121.0);
      final j = grid()
        ..['origin_lat'] = geo.lat
        ..['origin_lng'] = geo.lng;
      final g = PreviewGrid.fromJson(j, originLat: 14.0, originLng: 121.0)!;
      expect(g.x0, closeTo(10, 1e-3));
      expect(g.y0, closeTo(20, 1e-3));
    });

    test('reads per-cell confidence, and treats none as 1', () {
      final g = PreviewGrid.fromJson(
        {
          ...grid(),
          'confidence': [0.5, null, 2, -1],
        },
        originLat: 14.0,
        originLng: 121.0,
      )!;
      expect(g.confidenceAt(0, 0), 0.5);
      expect(g.confidenceAt(1, 0), 1.0); // no data, so no confidence: 1
      expect(g.confidenceAt(0, 1), 1.0); // clamped
      expect(g.confidenceAt(1, 1), 0.0);
      for (final j in [
        grid(), // grids stored before confidence existed
        {...grid(), 'confidence': null},
        {
          ...grid(),
          'confidence': [0.5], // the wrong size is ignored
        },
        {...grid(), 'confidence': 'nope'},
      ]) {
        final old = PreviewGrid.fromJson(j, originLat: 14, originLng: 121)!;
        expect(old.confidence, isNull);
        expect(old.confidenceAt(1, 1), 1.0);
      }
    });

    test('refuses grids that cannot be drawn', () {
      for (final j in [
        grid(cols: 0),
        grid(rows: 0),
        grid(values: [1, 2, 3]),
        {...grid(), 'cell_size_m': 0},
        {...grid(), 'values': 'nope'},
      ]) {
        expect(PreviewGrid.fromJson(j, originLat: 14, originLng: 121), isNull);
      }
    });
  });

  group('pickPreviewGrid', () {
    test('takes the strongest-signal grid of the floor', () {
      final response = {
        'computed_at': '2026-11-16T10:00:00Z',
        'grids': [
          grid(floorId: 'f2'),
          grid(bssid: 'aa:bb:cc:dd:ee:ff'),
          grid(values: [-40, -40, -40, -40]),
        ],
      };
      final g = pickPreviewGrid(response, 'f1', originLat: 14, originLng: 121)!;
      expect(g.floorId, 'f1');
      expect(g.at(0, 0), -40);
    });

    test('is null when the floor has no grid yet', () {
      expect(
        pickPreviewGrid({'grids': []}, 'f1', originLat: 14, originLng: 121),
        isNull,
      );
      expect(pickPreviewGrid({}, 'f1', originLat: 14, originLng: 121), isNull);
    });
  });

  group('plan image check', () {
    final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0];
    final jpg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0];

    test('accepts PNG and JPEG by their first bytes', () {
      expect(checkPlanBytes(png), PlanCheck.ok);
      expect(checkPlanBytes(jpg), PlanCheck.ok);
      expect(planMediaType(png), 'image/png');
      expect(planMediaType(jpg), 'image/jpeg');
    });

    test('rejects other files, empty files and files over 5 MB', () {
      expect(
        checkPlanBytes([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
        PlanCheck.notImage,
      );
      expect(checkPlanBytes(const []), PlanCheck.empty);
      expect(
        checkPlanBytes([...jpg, ...List.filled(maxPlanBytes, 0)]),
        PlanCheck.tooLarge,
      );
      expect(
        checkPlanBytes(List.filled(maxPlanBytes, 0xFF)),
        PlanCheck.notImage,
      );
    });

    test('exactly 5 MB is allowed', () {
      final bytes = [...jpg, ...List.filled(maxPlanBytes - jpg.length, 0)];
      expect(bytes.length, maxPlanBytes);
      expect(checkPlanBytes(bytes), PlanCheck.ok);
    });

    test('every failure has a message', () {
      for (final c in PlanCheck.values.where((c) => c != PlanCheck.ok)) {
        expect(planCheckMessage(c), isNotEmpty);
      }
      expect(planCheckMessage(PlanCheck.ok), '');
    });
  });

  group('form checks', () {
    test('name and email', () {
      expect(validateName(''), isNotNull);
      expect(validateName('  '), isNotNull);
      expect(validateName('A' * 101), isNotNull);
      expect(validateName('Boon'), isNull);
      expect(validateEmail(''), isNotNull);
      expect(validateEmail('nope'), isNotNull);
      expect(validateEmail('a@b'), isNotNull);
      expect(validateEmail(' a@b.co '), isNull);
    });

    test('password length', () {
      expect(validateNewPassword('1234567'), isNotNull);
      expect(validateNewPassword('12345678'), isNull);
      expect(validateNewPassword('x' * 129), isNotNull);
    });

    test('building fields', () {
      expect(validateBuildingName(' '), isNotNull);
      expect(validateBuildingName('x' * 201), isNotNull);
      expect(validateBuildingName('Main'), isNull);
      expect(validateAddress('x' * 501), isNotNull);
      expect(validateAddress(''), isNull);
      expect(validateDescription('x' * 2001), isNotNull);
      expect(validateDescription('ok'), isNull);
    });

    test('floor fields', () {
      expect(validateFloorLabel(''), isNotNull);
      expect(validateFloorLabel('x' * 51), isNotNull);
      expect(validateFloorLabel('Lobby'), isNull);
      expect(validateFloorLevel('abc'), isNotNull);
      expect(validateFloorLevel('1.5'), isNotNull);
      expect(validateFloorLevel('-21'), isNotNull);
      expect(validateFloorLevel('201'), isNotNull);
      expect(validateFloorLevel('-2'), isNull);
      expect(validateHeight('abc'), isNotNull);
      expect(validateHeight('0'), isNotNull);
      expect(validateHeight('100'), isNotNull);
      expect(validateHeight('3.2'), isNull);
      expect(validateOptionalSize(''), isNull);
      expect(validateOptionalSize('x'), isNotNull);
      expect(validateOptionalSize('0'), isNotNull);
      expect(validateOptionalSize('10000'), isNotNull);
      expect(validateOptionalSize('25.5'), isNull);
    });

    test('next floor suggestion', () {
      expect(suggestNextFloor(const []), (level: 0, label: 'Ground floor'));
      expect(suggestNextFloor(const [0, 1]), (level: 2, label: 'Floor 2'));
      expect(suggestNextFloor(const [-2, -1]), (
        level: 0,
        label: 'Ground floor',
      ));
    });
  });
}
