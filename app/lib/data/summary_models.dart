/// One floor of `GET /surveys/{id}/summary` (FR-19).
class FloorSummary {
  const FloorSummary({
    required this.level,
    required this.label,
    required this.rawReadings,
    required this.cleanedReadings,
    required this.areaM2,
    required this.goodPct,
    required this.fairPct,
    required this.deadPct,
    required this.accessPoints,
  });

  factory FloorSummary.fromJson(Map<String, dynamic> j) => FloorSummary(
    level: (j['floor_level'] as num).toInt(),
    label: j['floor_label'] as String,
    rawReadings: (j['raw_reading_count'] as num).toInt(),
    cleanedReadings: (j['cleaned_reading_count'] as num).toInt(),
    areaM2: (j['area_covered_m2'] as num).toDouble(),
    goodPct: (j['good_pct'] as num).toDouble(),
    fairPct: (j['fair_pct'] as num).toDouble(),
    deadPct: (j['dead_pct'] as num).toDouble(),
    accessPoints: (j['access_point_count'] as num).toInt(),
  );

  final int level;
  final String label;
  final int rawReadings;
  final int cleanedReadings;
  final double areaM2;
  final double goodPct;
  final double fairPct;
  final double deadPct;
  final int accessPoints;

  /// A floor with no cleaned readings has no coverage to describe.
  bool get hasCoverage => cleanedReadings > 0 && areaM2 > 0;
}

/// A processed survey's summary: totals and one entry per floor.
class SurveySummaryData {
  const SurveySummaryData({
    required this.surveyId,
    required this.status,
    required this.processedAt,
    required this.floors,
  });

  factory SurveySummaryData.fromJson(Map<String, dynamic> j) =>
      SurveySummaryData(
        surveyId: j['survey_id'] as String? ?? '',
        status: j['status'] as String? ?? 'processed',
        processedAt: j['processed_at'] == null
            ? null
            : DateTime.parse(j['processed_at'] as String),
        floors: [
          for (final f in j['floors'] as List)
            FloorSummary.fromJson(f as Map<String, dynamic>),
        ]..sort((a, b) => a.level.compareTo(b.level)),
      );

  final String surveyId;
  final String status;
  final DateTime? processedAt;
  final List<FloorSummary> floors;

  int get rawReadings => floors.fold(0, (n, f) => n + f.rawReadings);
  int get cleanedReadings => floors.fold(0, (n, f) => n + f.cleanedReadings);
  int get accessPoints => floors.fold(0, (n, f) => n + f.accessPoints);
  double get areaM2 => floors.fold(0.0, (n, f) => n + f.areaM2);

  /// Share of the covered area that is good, fair or dead over all floors,
  /// weighted by each floor's area. Zero when nothing is covered.
  double _weighted(double Function(FloorSummary) pct) {
    final area = areaM2;
    if (area <= 0) return 0;
    return floors.fold(0.0, (n, f) => n + pct(f) * f.areaM2) / area;
  }

  double get goodPct => _weighted((f) => f.goodPct);
  double get fairPct => _weighted((f) => f.fairPct);
  double get deadPct => _weighted((f) => f.deadPct);
}
