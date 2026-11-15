import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/sync_engine.dart';
import '../config.dart';
import 'models.dart';

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

  Future<User> me() async =>
      User.fromJson(await _send('GET', '/auth/me') as Map<String, dynamic>);

  Future<void> giveConsent() async {
    await _send('POST', '/auth/me/consent');
  }

  // --- buildings and floors ---

  Future<List<Building>> buildings() async {
    final json =
        await _send(
              'GET',
              '/buildings',
              query: {'page_size': '100', 'sort': 'name'},
            )
            as Map<String, dynamic>;
    return [
      for (final b in json['items'] as List)
        Building.fromJson(b as Map<String, dynamic>),
    ];
  }

  Future<Building> building(String id) async => Building.fromJson(
    await _send('GET', '/buildings/$id') as Map<String, dynamic>,
  );

  Future<Building> createBuilding(String name) async => Building.fromJson(
    await _send('POST', '/buildings', body: {'name': name})
        as Map<String, dynamic>,
  );

  Future<Floor> createFloor(String buildingId, int level, String label) async =>
      Floor.fromJson(
        await _send(
              'POST',
              '/buildings/$buildingId/floors',
              body: {'level': level, 'label': label},
            )
            as Map<String, dynamic>,
      );

  // --- surveys ---

  Future<String> createSurvey({
    required String buildingId,
    required double originLat,
    required double originLng,
    required double originAccuracyM,
    String? deviceModel,
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
              },
            )
            as Map<String, dynamic>;
    return json['id'] as String;
  }

  Future<void> setSurveyStatus(String surveyId, String status) async {
    await _send('PATCH', '/surveys/$surveyId', body: {'status': status});
  }

  Future<void> process(String surveyId) async {
    await _send('POST', '/surveys/$surveyId/process');
  }

  Future<void> postBatch(PendingBatch batch) async {
    final key = batch.kind == SyncKind.readings ? 'readings' : 'checkpoints';
    await _send(
      'POST',
      '/surveys/${batch.surveyId}/$key',
      body: {key: batch.items},
    );
  }

  /// Address of the 3D page. The token is in the fragment, which is never sent
  /// to a server, so it stays out of access logs.
  Uri viewerUri(String surveyId) => Uri.parse(
    '$baseUrl/api/viewer/#survey=$surveyId&token=${Uri.encodeComponent(token ?? '')}',
  );
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
      throw SyncException(e.message, retryable: retryable);
    }
  }
}
