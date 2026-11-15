import '../core/levels.dart';

class User {
  const User({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.consented,
    required this.thresholds,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'] as String,
    email: j['email'] as String,
    name: j['name'] as String,
    role: j['role'] as String,
    consented: j['consented_at'] != null,
    thresholds: Thresholds(
      goodDbm: (j['good_threshold_dbm'] as num).toInt(),
      deadDbm: (j['dead_threshold_dbm'] as num).toInt(),
    ),
  );

  final String id;
  final String email;
  final String name;
  final String role;
  final bool consented;
  final Thresholds thresholds;

  /// The API asks Surveyors for privacy consent before their first survey.
  bool get needsConsent => role == 'surveyor' && !consented;
}

class Floor {
  const Floor({required this.id, required this.level, required this.label});

  factory Floor.fromJson(Map<String, dynamic> j) => Floor(
    id: j['id'] as String,
    level: (j['level'] as num).toInt(),
    label: j['label'] as String,
  );

  final String id;
  final int level;
  final String label;
}

class Building {
  const Building({
    required this.id,
    required this.name,
    this.floors = const [],
  });

  factory Building.fromJson(Map<String, dynamic> j) => Building(
    id: j['id'] as String,
    name: j['name'] as String,
    floors: [
      for (final f in (j['floors'] as List? ?? const []))
        Floor.fromJson(f as Map<String, dynamic>),
    ]..sort((a, b) => a.level.compareTo(b.level)),
  );

  final String id;
  final String name;
  final List<Floor> floors;
}
