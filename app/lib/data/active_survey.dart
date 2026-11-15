/// What the phone remembers about a survey that has been started but not
/// finished, so the next launch can offer to resume or end it.
class ActiveSurvey {
  const ActiveSurvey({
    required this.surveyId,
    required this.userId,
    required this.buildingId,
    required this.buildingName,
    required this.floorId,
    required this.originLat,
    required this.originLng,
    required this.x,
    required this.y,
    required this.steps,
    required this.checkpointSteps,
    required this.startedMs,
    required this.readings,
    required this.checkpoints,
  });

  factory ActiveSurvey.fromRow(Map<String, Object?> r) => ActiveSurvey(
    surveyId: r['survey_id']! as String,
    userId: r['user_id']! as String,
    buildingId: r['building_id']! as String,
    buildingName: r['building_name']! as String,
    floorId: r['floor_id']! as String,
    originLat: (r['origin_lat']! as num).toDouble(),
    originLng: (r['origin_lng']! as num).toDouble(),
    x: (r['x']! as num).toDouble(),
    y: (r['y']! as num).toDouble(),
    steps: (r['steps']! as num).toInt(),
    checkpointSteps: (r['checkpoint_steps']! as num).toInt(),
    startedMs: (r['started_ms']! as num).toInt(),
    readings: (r['readings']! as num).toInt(),
    checkpoints: (r['checkpoints']! as num).toInt(),
  );

  Map<String, Object?> toRow() => {
    'id': 1,
    'survey_id': surveyId,
    'user_id': userId,
    'building_id': buildingId,
    'building_name': buildingName,
    'floor_id': floorId,
    'origin_lat': originLat,
    'origin_lng': originLng,
    'x': x,
    'y': y,
    'steps': steps,
    'checkpoint_steps': checkpointSteps,
    'started_ms': startedMs,
    'readings': readings,
    'checkpoints': checkpoints,
  };

  final String surveyId;
  final String userId;
  final String buildingId;
  final String buildingName;
  final String floorId;
  final double originLat;
  final double originLng;

  /// Last dead-reckoned position, metres from the origin.
  final double x;
  final double y;
  final int steps;

  /// Step count at the last checkpoint, where drift correction restarts.
  final int checkpointSteps;
  final int startedMs;
  final int readings;
  final int checkpoints;
}
