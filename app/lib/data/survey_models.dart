/// A survey as the history list shows it (one item of `GET /surveys`).
class SurveyInfo {
  const SurveyInfo({
    required this.id,
    required this.buildingId,
    required this.surveyorId,
    required this.status,
    required this.startedAt,
    this.endedAt,
    this.processedAt,
    this.deviceModel,
    this.notes,
  });

  factory SurveyInfo.fromJson(Map<String, dynamic> j) => SurveyInfo(
    id: j['id'] as String,
    buildingId: j['building_id'] as String,
    surveyorId: j['surveyor_id'] as String,
    status: j['status'] as String,
    startedAt: DateTime.parse(j['started_at'] as String),
    endedAt: j['ended_at'] == null
        ? null
        : DateTime.parse(j['ended_at'] as String),
    processedAt: j['processed_at'] == null
        ? null
        : DateTime.parse(j['processed_at'] as String),
    deviceModel: j['device_model'] as String?,
    notes: j['notes'] as String?,
  );

  final String id;
  final String buildingId;
  final String surveyorId;

  /// `active`, `paused`, `completed` or `processed`.
  final String status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime? processedAt;
  final String? deviceModel;
  final String? notes;

  bool get isProcessed => status == 'processed';

  /// Plain words for the status chip.
  String get statusLabel => switch (status) {
    'active' => 'In progress',
    'paused' => 'Paused',
    'completed' => 'Not processed',
    'processed' => 'Processed',
    _ => status,
  };
}

/// One page of `GET /surveys`.
class SurveyPage {
  const SurveyPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory SurveyPage.fromJson(Map<String, dynamic> j) => SurveyPage(
    items: [
      for (final s in j['items'] as List)
        SurveyInfo.fromJson(s as Map<String, dynamic>),
    ],
    total: (j['total'] as num).toInt(),
    page: (j['page'] as num).toInt(),
    pageSize: (j['page_size'] as num).toInt(),
  );

  final List<SurveyInfo> items;
  final int total;
  final int page;
  final int pageSize;
}

/// Surveyors and Admins may delete a survey; Viewers only look.
bool canDeleteSurveys(String role) => role != 'viewer';
