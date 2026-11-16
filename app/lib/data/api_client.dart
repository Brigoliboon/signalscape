import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

import '../core/sync_engine.dart';
import '../config.dart';
import 'user_models.dart';
import 'models.dart';
import 'survey_models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  /// 0 when the server could not be reached.
  final int statusCode;
  final String message;

  bool get isNetwork => statusCode == 0;
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// Thin client for the SignalScape REST API (`/api`).
class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
    : _http = client ?? http.Client(),
      baseUrl = (baseUrl ?? apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final http.Client _http;
  final String baseUrl;
  String? token;

  /// Called when the API answers 401, so the app can go back to sign in.
  void Function()? onUnauthorized;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl/api$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Map<String, String>? form,
  }) async {
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(_headers);
    if (form != null) {
      request.bodyFields = form;
    } else if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 30)),
      );
    } on TimeoutException {
      throw ApiException(0, 'The server did not answer in time.');
    } on SocketException {
      throw ApiException(0, 'No connection to the server.');
    } on http.ClientException {
      throw ApiException(0, 'No connection to the server.');
    }
    if (response.statusCode == 401 && token != null) onUnauthorized?.call();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      return jsonDecode(utf8.decode(response.bodyBytes));
    }
    throw ApiException(response.statusCode, _detail(response));
  }

  static String _detail(http.Response r) {
    try {
      final detail = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['detail'];
      if (detail is String) return detail;
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map && first['msg'] is String) {
          return first['msg'] as String;
        }
      }
    } catch (_) {
      // fall through to the generic text
    }
    return 'Request failed (${r.statusCode}).';
  }

  // --- auth ---

  Future<String> login(String email, String password) async {
    final json =
        await _send(
              'POST',
              '/auth/login',
              form: {'username': email.trim(), 'password': password},
            )
            as Map<String, dynamic>;
    return json['access_token'] as String;
  }

  /// Creates a Surveyor account. Throws [ApiException] (409 if the email is
  /// already registered).
  Future<void> register(String name, String email, String password) async {
    await _send(
      'POST',
      '/auth/register',
      body: {'name': name.trim(), 'email': email.trim(), 'password': password},
    );
  }

  Future<User> me() async =>
      User.fromJson(await _send('GET', '/auth/me') as Map<String, dynamic>);

  Future<void> giveConsent() async {
    await _send('POST', '/auth/me/consent');
  }

  /// Saves the name and/or both signal thresholds of your profile and returns
  /// the new profile. The API wants dead below good (422 otherwise).
  Future<User> updateProfile({
    String? name,
    int? goodDbm,
    int? deadDbm,
  }) async => User.fromJson(
    await _send(
          'PATCH',
          '/auth/me',
          body: {
            'name': ?name,
            'good_threshold_dbm': ?goodDbm,
            'dead_threshold_dbm': ?deadDbm,
          },
        )
        as Map<String, dynamic>,
  );

  /// Changes the password. A wrong [current] password is a 400.
  Future<void> changePassword(String current, String next) async {
    await _send(
      'PATCH',
      '/auth/me',
      body: {'current_password': current, 'password': next},
    );
  }

  /// Deletes your account and everything it owns (204). An Admin who is the
  /// last active one is refused with a 409.
  Future<void> deleteAccount() async {
    await _send('DELETE', '/auth/me');
  }

  // --- buildings and floors ---

  /// One page of buildings. [sort] is `name`, `created_at`, or either with a
  /// `-` in front for descending.
  Future<BuildingPage> buildingPage({
    String q = '',
    int page = 1,
    int pageSize = 20,
    String sort = 'name',
  }) async => BuildingPage.fromJson(
    await _send(
          'GET',
          '/buildings',
          query: {
            if (q.trim().isNotEmpty) 'q': q.trim(),
            'page': '$page',
            'page_size': '$pageSize',
            'sort': sort,
          },
        )
        as Map<String, dynamic>,
  );

  Future<Building> building(String id) async => Building.fromJson(
    await _send('GET', '/buildings/$id') as Map<String, dynamic>,
  );

  Future<Building> createBuilding(
    String name, {
    String? address,
    String? description,
  }) async => Building.fromJson(
    await _send(
          'POST',
          '/buildings',
          body: {
            'name': name,
            'address': ?address,
            'description': ?description,
          },
        )
        as Map<String, dynamic>,
  );

  /// Sends all three fields, so an empty address or description is cleared.
  Future<Building> updateBuilding(
    String id, {
    required String name,
    String? address,
    String? description,
  }) async => Building.fromJson(
    await _send(
          'PATCH',
          '/buildings/$id',
          body: {'name': name, 'address': address, 'description': description},
        )
        as Map<String, dynamic>,
  );

  /// Deletes a building with its floors, floor plans and surveys (204).
  Future<void> deleteBuilding(String id) async {
    await _send('DELETE', '/buildings/$id');
  }

  /// Deletes a floor, its plan and the readings recorded on it (204).
  Future<void> deleteFloor(String id) async {
    await _send('DELETE', '/floors/$id');
  }

  Future<Floor> createFloor(
    String buildingId,
    int level,
    String label, {
    double? heightM,
    double? widthM,
    double? lengthM,
  }) async => Floor.fromJson(
    await _send(
          'POST',
          '/buildings/$buildingId/floors',
          body: {
            'level': level,
            'label': label,
            'height_m': ?heightM,
            'width_m': ?widthM,
            'length_m': ?lengthM,
          },
        )
        as Map<String, dynamic>,
  );

  /// Sends every field, so an emptied width or length is cleared.
  Future<Floor> updateFloor(
    String id, {
    required int level,
    required String label,
    required double heightM,
    double? widthM,
    double? lengthM,
  }) async => Floor.fromJson(
    await _send(
          'PATCH',
          '/floors/$id',
          body: {
            'level': level,
            'label': label,
            'height_m': heightM,
            'width_m': widthM,
            'length_m': lengthM,
          },
        )
        as Map<String, dynamic>,
  );

  /// Uploads or replaces a floor plan. The API accepts PNG or JPEG up to 5 MB.
  Future<Floor> uploadPlan(
    String floorId,
    List<int> bytes,
    String mediaType,
  ) async {
    final ext = mediaType == 'image/png' ? 'png' : 'jpg';
    final request = http.MultipartRequest('PUT', _uri('/floors/$floorId/plan'))
      ..headers.addAll(_headers)
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: 'plan.$ext',
          contentType: MediaType.parse(mediaType),
        ),
      );
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 60)),
      );
    } on TimeoutException {
      throw ApiException(0, 'The upload took too long. Try again.');
    } on SocketException {
      throw ApiException(0, 'No connection to the server.');
    } on http.ClientException {
      throw ApiException(0, 'No connection to the server.');
    }
    if (response.statusCode == 401 && token != null) onUnauthorized?.call();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return Floor.fromJson(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
      );
    }
    throw ApiException(response.statusCode, _detail(response));
  }

  /// Where a floor plan can be fetched, and the headers to fetch it with.
  Uri planUri(String planUrl) => Uri.parse('$baseUrl$planUrl');
  Map<String, String> get authHeaders => {
    if (token != null) 'Authorization': 'Bearer $token',
  };

  // --- surveys ---

  Future<String> createSurvey({
    required String buildingId,
    required double originLat,
    required double originLng,
    required double originAccuracyM,
    String? deviceModel,
    bool hasBarometer = false,
  }) async {
    final json =
        await _send(
              'POST',
              '/surveys',
              body: {
                'building_id': buildingId,
                'origin_lat': originLat,
                'origin_lng': originLng,
                'origin_accuracy_m': originAccuracyM,
                'device_model': ?deviceModel,
                'has_barometer': hasBarometer,
              },
            )
            as Map<String, dynamic>;
    return json['id'] as String;
  }

  Future<void> setSurveyStatus(String surveyId, String status) async {
    await _send('PATCH', '/surveys/$surveyId', body: {'status': status});
  }

  /// One page of the surveys you may see, newest first by default. [status]
  /// is `active`, `paused`, `completed` or `processed`.
  Future<SurveyPage> surveyPage({
    String? buildingId,
    String? status,
    int page = 1,
    int pageSize = 20,
    String sort = '-started_at',
  }) async => SurveyPage.fromJson(
    await _send(
          'GET',
          '/surveys',
          query: {
            'building_id': ?buildingId,
            'status': ?status,
            'page': '$page',
            'page_size': '$pageSize',
            'sort': sort,
          },
        )
        as Map<String, dynamic>,
  );

  /// Deletes a survey with its readings and results (204).
  Future<void> deleteSurvey(String surveyId) async {
    await _send('DELETE', '/surveys/$surveyId');
  }

  Future<void> process(String surveyId) async {
    await _send('POST', '/surveys/$surveyId/process');
  }

  /// Live preview heatmap: processes what the API has so far for one floor,
  /// saves nothing, and returns the strongest-signal grids.
  Future<Map<String, dynamic>> processPreview(
    String surveyId,
    String floorId,
  ) async =>
      await _send(
            'POST',
            '/surveys/$surveyId/process',
            query: {'preview': 'true', 'floor_id': floorId},
          )
          as Map<String, dynamic>;

  Future<void> postBatch(PendingBatch batch) async {
    final key = batch.kind == SyncKind.readings ? 'readings' : 'checkpoints';
    await _send(
      'POST',
      '/surveys/${batch.surveyId}/$key',
      body: {key: batch.items},
    );
  }

  /// Coverage cells and access points of a processed survey as GeoJSON, one
  /// feature per cell or point, each with its `floor_level` (FR-16a). The API's
  /// default is cells and access points. With [bssid] they are only that
  /// network's; without it the cells are the strongest signal of any network.
  Future<Map<String, dynamic>> surveyGeoJson(
    String surveyId, {
    String? bssid,
  }) async =>
      await _send('GET', '/surveys/$surveyId/geojson', query: {'bssid': ?bssid})
          as Map<String, dynamic>;

  /// Every network seen in the survey (SSID and BSSID pairs), most readings
  /// first. Works before processing.
  Future<List<Map<String, dynamic>>> surveyNetworks(String surveyId) async {
    final items = <Map<String, dynamic>>[];
    for (var page = 1; page <= 10; page++) {
      final json =
          await _send(
                'GET',
                '/surveys/$surveyId/networks',
                query: {
                  'sort': '-reading_count',
                  'page': '$page',
                  'page_size': '100',
                },
              )
              as Map<String, dynamic>;
      final got = (json['items'] as List).cast<Map<String, dynamic>>();
      items.addAll(got);
      if (got.isEmpty || items.length >= (json['total'] as num).toInt()) break;
    }
    return items;
  }

  /// The walk, per floor, with its start and end.
  Future<Map<String, dynamic>> surveyTrail(String surveyId) async =>
      await _send('GET', '/surveys/$surveyId/trail') as Map<String, dynamic>;

  /// Floor names and counts of a processed survey; 409 until it is processed.
  Future<Map<String, dynamic>> surveySummary(String surveyId) async =>
      await _send('GET', '/surveys/$surveyId/summary') as Map<String, dynamic>;

  /// All readings of a survey as CSV, as the API sends them (FR-21).
  Future<List<int>> exportCsv(String surveyId) async {
    final request = http.Request('GET', _uri('/surveys/$surveyId/export.csv'))
      ..headers.addAll({..._headers, 'Accept': 'text/csv'});
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _http.send(request).timeout(const Duration(seconds: 120)),
      );
    } on TimeoutException {
      throw ApiException(0, 'The export took too long. Try again.');
    } on SocketException {
      throw ApiException(0, 'No connection to the server.');
    } on http.ClientException {
      throw ApiException(0, 'No connection to the server.');
    }
    if (response.statusCode == 401 && token != null) onUnauthorized?.call();
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.bodyBytes;
    }
    throw ApiException(response.statusCode, _detail(response));
  }

  /// Address of the 3D page. The token is in the fragment, which is never sent
  /// to a server, so it stays out of access logs.
  Uri viewerUri(String surveyId) => Uri.parse(
    '$baseUrl/api/viewer/#survey=$surveyId&token=${Uri.encodeComponent(token ?? '')}',
  );

  // --- administration (Admins only; anyone else gets 403) ---

  /// One page of users. [sort] is `created_at`, `name` or `email`, with a `-`
  /// in front for descending.
  Future<UserPage> userPage({
    String q = '',
    String? role,
    bool? isActive,
    int page = 1,
    int pageSize = 20,
    String sort = '-created_at',
  }) async => UserPage.fromJson(
    await _send(
          'GET',
          '/users',
          query: {
            if (q.trim().isNotEmpty) 'q': q.trim(),
            'role': ?role,
            if (isActive != null) 'is_active': '$isActive',
            'page': '$page',
            'page_size': '$pageSize',
            'sort': sort,
          },
        )
        as Map<String, dynamic>,
  );

  /// Sets a user's role and/or whether the account is active. Demoting or
  /// deactivating the last active Admin is a 409.
  Future<AdminUser> updateUser(
    String id, {
    String? role,
    bool? isActive,
  }) async => AdminUser.fromJson(
    await _send(
          'PATCH',
          '/users/$id',
          body: {'role': ?role, 'is_active': ?isActive},
        )
        as Map<String, dynamic>,
  );

  /// Deletes a user and everything they own (204). The last active Admin is
  /// refused with a 409.
  Future<void> deleteUser(String id) async {
    await _send('DELETE', '/users/$id');
  }
}

/// Sends sync batches through [ApiClient] and sorts failures into ones worth
/// retrying and ones that need a person.
class ApiSyncTransport implements SyncTransport {
  ApiSyncTransport(this.api);

  final ApiClient api;

  @override
  Future<void> send(PendingBatch batch) async {
    try {
      await api.postBatch(batch);
    } on ApiException catch (e) {
      final retryable =
          e.isNetwork ||
          e.statusCode >= 500 ||
          e.statusCode == 408 ||
          e.statusCode == 429;
      throw SyncException(
        e.message,
        retryable: retryable,
        statusCode: e.statusCode,
      );
    }
  }
}
