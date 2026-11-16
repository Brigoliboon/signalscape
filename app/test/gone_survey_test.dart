import 'package:flutter_test/flutter_test.dart';
import 'package:signalscape_mobile/data/active_survey.dart';
import 'package:signalscape_mobile/survey/gone_survey.dart';

import 'support.dart';

const survey = ActiveSurvey(
  surveyId: 's1',
  userId: 'u1',
  buildingId: 'b1',
  buildingName: 'Main Tower',
  floorId: 'f0',
  originLat: 14.5,
  originLng: 121.0,
  x: 0,
  y: 0,
  steps: 0,
  checkpointSteps: 0,
  startedMs: 1,
  readings: 1,
  checkpoints: 0,
);

void main() {
  test('isGoneStatus is only true for 404', () {
    expect(isGoneStatus(404), isTrue);
    expect(isGoneStatus(0), isFalse);
    expect(isGoneStatus(401), isFalse);
    expect(isGoneStatus(409), isFalse);
    expect(isGoneStatus(500), isFalse);
    expect(isGoneStatus(null), isFalse);
  });

  test('a missing building is gone', () async {
    final api = apiFor((_) async => jsonResponse({'detail': 'Not found'}, 404));
    expect(await localSurveyTargetGone(api, survey), isTrue);
  });

  test('a building without this floor is gone', () async {
    final api = apiFor(
      (_) async => jsonResponse(
        buildingJson('b1', 'Main Tower', floors: [floorJson('f1', 1, 'First')]),
      ),
    );
    expect(await localSurveyTargetGone(api, survey), isTrue);
  });

  test('a building that still has this floor is not gone', () async {
    final api = apiFor(
      (_) async => jsonResponse(
        buildingJson(
          'b1',
          'Main Tower',
          floors: [floorJson('f0', 0, 'Ground')],
        ),
      ),
    );
    expect(await localSurveyTargetGone(api, survey), isFalse);
  });

  test('a server error is not treated as gone', () async {
    final api = apiFor((_) async => jsonResponse({'detail': 'boom'}, 500));
    expect(await localSurveyTargetGone(api, survey), isFalse);
  });
}
