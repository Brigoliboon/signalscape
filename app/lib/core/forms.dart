// Checks for the register, building and floor forms. Each returns an error
// message for the screen, or null when the value is fine. The limits are the
// API's, so a form that passes here will not bounce off the server.

String? validateName(String v, {String what = 'name'}) {
  final t = v.trim();
  if (t.isEmpty) return 'Enter your $what.';
  if (t.length > 100) return 'Keep the $what under 100 characters.';
  return null;
}

String? validateEmail(String v) {
  final t = v.trim();
  if (t.isEmpty) return 'Enter your email.';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(t)) {
    return 'That does not look like an email address.';
  }
  return null;
}

String? validateNewPassword(String v) {
  if (v.length < 8) return 'Use at least 8 characters.';
  if (v.length > 128) return 'Use at most 128 characters.';
  return null;
}

String? validateBuildingName(String v) {
  final t = v.trim();
  if (t.isEmpty) return 'Give the building a name.';
  if (t.length > 200) return 'Keep the name under 200 characters.';
  return null;
}

String? validateAddress(String v) =>
    v.trim().length > 500 ? 'Keep the address under 500 characters.' : null;

String? validateDescription(String v) => v.trim().length > 2000
    ? 'Keep the description under 2000 characters.'
    : null;

String? validateFloorLabel(String v) {
  final t = v.trim();
  if (t.isEmpty) return 'Give the floor a label.';
  if (t.length > 50) return 'Keep the label under 50 characters.';
  return null;
}

const int minFloorLevel = -20;
const int maxFloorLevel = 200;

String? validateFloorLevel(String v) {
  final n = int.tryParse(v.trim());
  if (n == null) return 'Level must be a whole number (0 = ground).';
  if (n < minFloorLevel || n > maxFloorLevel) {
    return 'Level must be between $minFloorLevel and $maxFloorLevel.';
  }
  return null;
}

/// Storey height in metres. Typical storeys are 3 to 3.5 m.
String? validateHeight(String v) {
  final n = double.tryParse(v.trim());
  if (n == null) return 'Enter the height in metres, for example 3.2.';
  if (n <= 0 || n >= 100) return 'Height must be above 0 and below 100 m.';
  return null;
}

/// An optional size in metres: empty is fine.
String? validateOptionalSize(String v) {
  if (v.trim().isEmpty) return null;
  final n = double.tryParse(v.trim());
  if (n == null) return 'Enter a number in metres, or leave it empty.';
  if (n <= 0 || n >= 10000) return 'Size must be above 0 and below 10000 m.';
  return null;
}

/// A suggestion for a new floor's level and label, one above the highest.
({int level, String label}) suggestNextFloor(Iterable<int> levels) {
  final next = levels.isEmpty ? 0 : levels.reduce((a, b) => a > b ? a : b) + 1;
  return (level: next, label: next == 0 ? 'Ground floor' : 'Floor $next');
}
