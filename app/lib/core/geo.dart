import 'dart:math' as math;

/// Same projection as the API (`app/services/processing.py`), so a position
/// worked out on the phone lands where the API expects it.
const double earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// Projects lat/lng to (x east, y north) metres around the origin.
({double x, double y}) toLocal(
  double lat,
  double lng,
  double originLat,
  double originLng,
) {
  final y = _rad(lat - originLat) * earthRadiusM;
  final x = _rad(lng - originLng) * earthRadiusM * math.cos(_rad(originLat));
  return (x: x, y: y);
}

/// Inverse of [toLocal].
({double lat, double lng}) toGeo(
  double x,
  double y,
  double originLat,
  double originLng,
) {
  final lat = originLat + _deg(y / earthRadiusM);
  final lng = originLng + _deg(x / (earthRadiusM * math.cos(_rad(originLat))));
  return (lat: lat, lng: lng);
}
