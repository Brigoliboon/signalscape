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
  const Floor({
    required this.id,
    required this.level,
    required this.label,
    this.heightM = defaultFloorHeightM,
    this.widthM,
    this.lengthM,
    this.planUrl,
  });

  factory Floor.fromJson(Map<String, dynamic> j) => Floor(
    id: j['id'] as String,
    level: (j['level'] as num).toInt(),
    label: j['label'] as String,
    heightM: (j['height_m'] as num?)?.toDouble() ?? defaultFloorHeightM,
    widthM: (j['width_m'] as num?)?.toDouble(),
    lengthM: (j['length_m'] as num?)?.toDouble(),
    planUrl: j['plan_url'] as String?,
  );

  /// The API's default storey height.
  static const double defaultFloorHeightM = 3.0;

  final String id;
  final int level;
  final String label;

  /// Storey height in metres. The barometer uses it to count floors.
  final double heightM;
  final double? widthM;
  final double? lengthM;

  /// Path of the uploaded floor plan on the API, or null if none.
  final String? planUrl;

  bool get hasPlan => planUrl != null;
}

class Building {
  const Building({
    required this.id,
    required this.name,
    this.address,
    this.description,
    this.floors = const [],
  });

  factory Building.fromJson(Map<String, dynamic> j) => Building(
    id: j['id'] as String,
    name: j['name'] as String,
    address: j['address'] as String?,
    description: j['description'] as String?,
    floors: [
      for (final f in (j['floors'] as List? ?? const []))
        Floor.fromJson(f as Map<String, dynamic>),
    ]..sort((a, b) => a.level.compareTo(b.level)),
  );

  final String id;
  final String name;
  final String? address;
  final String? description;
  final List<Floor> floors;
}

/// One page of `GET /buildings`.
class BuildingPage {
  const BuildingPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory BuildingPage.fromJson(Map<String, dynamic> j) => BuildingPage(
    items: [
      for (final b in j['items'] as List)
        Building.fromJson(b as Map<String, dynamic>),
    ],
    total: (j['total'] as num).toInt(),
    page: (j['page'] as num).toInt(),
    pageSize: (j['page_size'] as num).toInt(),
  );

  final List<Building> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;
}

/// Roles that may create and edit buildings and floors. Viewers only read.
bool canEditBuildings(User user) => user.role != 'viewer';
