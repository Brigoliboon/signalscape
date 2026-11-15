import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:signalscape_mobile/data/api_client.dart';
import 'package:signalscape_mobile/data/local_db.dart';
import 'package:signalscape_mobile/data/models.dart';
import 'package:signalscape_mobile/data/session.dart';
import 'package:signalscape_mobile/data/token_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Makes sqflite run on the host with a throwaway in-memory database.
void useFfiSqlite() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

Future<LocalDb> memoryDb() => LocalDb.openIn(inMemoryDatabasePath);

class MemoryTokens extends TokenStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String token) async => value = token;

  @override
  Future<void> clear() async => value = null;
}

Map<String, dynamic> userJson({
  String role = 'surveyor',
  bool consented = true,
}) => {
  'id': 'u1',
  'email': 'a@b.co',
  'name': 'A',
  'role': role,
  'is_active': true,
  'consented_at': consented ? '2026-11-01T00:00:00Z' : null,
  'good_threshold_dbm': -67,
  'dead_threshold_dbm': -80,
};

Map<String, dynamic> buildingJson(
  String id,
  String name, {
  String? address,
  List<Map<String, dynamic>> floors = const [],
}) => {
  'id': id,
  'owner_id': 'u1',
  'name': name,
  'address': address,
  'description': null,
  'created_at': '2026-11-01T00:00:00Z',
  'updated_at': '2026-11-01T00:00:00Z',
  'floors': floors,
};

Map<String, dynamic> floorJson(
  String id,
  int level,
  String label, {
  double height = 3.0,
  String? planUrl,
}) => {
  'id': id,
  'building_id': 'b1',
  'level': level,
  'label': label,
  'width_m': null,
  'length_m': null,
  'height_m': height,
  'plan_url': planUrl,
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

ApiClient apiFor(MockClientHandler handler) =>
    ApiClient(client: MockClient(handler), baseUrl: 'https://x.test');

/// A signed-in session whose API answers with [handler].
Session signedIn(MockClientHandler handler, {String role = 'surveyor'}) {
  final session = Session(api: apiFor(handler), tokens: MemoryTokens())
    ..state = SessionState.signedIn
    ..user = User.fromJson(userJson(role: role));
  session.api.token = 'tok';
  return session;
}
