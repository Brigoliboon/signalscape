/// Floor plan limits, the same as the API's (`PUT /floors/{id}/plan`).
const int maxPlanBytes = 5 * 1024 * 1024;

enum PlanCheck { ok, empty, tooLarge, notImage }

/// Checks a picked file before it is uploaded: PNG or JPEG by its first bytes
/// (not its name), and at most 5 MB.
PlanCheck checkPlanBytes(List<int> bytes) {
  if (bytes.isEmpty) return PlanCheck.empty;
  if (bytes.length > maxPlanBytes) return PlanCheck.tooLarge;
  return planMediaType(bytes) == null ? PlanCheck.notImage : PlanCheck.ok;
}

/// `image/png` or `image/jpeg` by magic bytes, or null for anything else.
String? planMediaType(List<int> bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  return null;
}

String planCheckMessage(PlanCheck c) => switch (c) {
  PlanCheck.ok => '',
  PlanCheck.empty => 'That file is empty.',
  PlanCheck.tooLarge => 'The floor plan must be 5 MB or smaller.',
  PlanCheck.notImage => 'The floor plan must be a PNG or JPEG image.',
};
