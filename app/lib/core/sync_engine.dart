import 'dart:async';

/// Offline-first upload (FR-11, FR-12). Rows are written to a local store first
/// and sent in batches; a row is marked synced only after the API said 2xx.
/// Duplicate `client_id`s are skipped by the API, so resending is safe.
enum SyncKind { readings, checkpoints }

class PendingBatch {
  PendingBatch({
    required this.surveyId,
    required this.kind,
    required this.ids,
    required this.items,
  });

  final String surveyId;
  final SyncKind kind;

  /// `client_id` of each item, same order as [items].
  final List<String> ids;

  /// JSON bodies as the API expects them.
  final List<Map<String, dynamic>> items;
}

abstract class SyncStore {
  /// Up to [limit] unsynced items of one survey and kind, or null if none.
  Future<PendingBatch?> nextBatch(int limit);
  Future<void> markSynced(PendingBatch batch);
  Future<int> pendingCount({String? surveyId});
}

abstract class SyncTransport {
  /// Sends a batch. Throws [SyncException] on failure.
  Future<void> send(PendingBatch batch);
}

class SyncException implements Exception {
  SyncException(this.message, {required this.retryable, this.statusCode});

  final String message;

  /// Network trouble, 5xx, 408 and 429 can be retried; other errors need a
  /// person (for example a 401 or a survey that is already completed).
  final bool retryable;

  /// HTTP status when the failure came from the API; null for network errors.
  final int? statusCode;

  /// The survey (or its building) is gone on the server, so retrying will
  /// not help and the local copy can be discarded.
  bool get isGone => statusCode == 404;

  @override
  String toString() => message;
}

class SyncResult {
  const SyncResult({required this.sent, this.error});

  final int sent;
  final SyncException? error;

  bool get ok => error == null;
}

class SyncEngine {
  SyncEngine({
    required this.store,
    required this.transport,
    this.batchSize = 500,
    Future<void> Function(Duration)? delay,
  }) : _delay = delay ?? Future<void>.delayed;

  final SyncStore store;
  final SyncTransport transport;
  final int batchSize;
  final Future<void> Function(Duration) _delay;

  /// Waits after the n-th failure in a row: 5 s, 10 s, 30 s, then 2 min.
  static const List<Duration> backoff = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];

  static Duration backoffFor(int failures) {
    if (failures <= 0) return Duration.zero;
    final i = failures - 1;
    return backoff[i < backoff.length ? i : backoff.length - 1];
  }

  Future<SyncResult>? _running;

  /// Sends batches until nothing is left or one fails. Only one run at a time;
  /// a second call joins the first.
  Future<SyncResult> pump() => _running ??= _pump().whenComplete(() {
    _running = null;
  });

  Future<SyncResult> _pump() async {
    var sent = 0;
    while (true) {
      final batch = await store.nextBatch(batchSize);
      if (batch == null) return SyncResult(sent: sent);
      try {
        await transport.send(batch);
      } on SyncException catch (e) {
        return SyncResult(sent: sent, error: e);
      }
      await store.markSynced(batch);
      sent += batch.ids.length;
    }
  }

  /// Keeps pumping, waiting by [backoffFor] between failures, until the queue
  /// is empty. Throws the last [SyncException] if a failure cannot be retried
  /// or if [maxFailures] failures happen in a row.
  Future<void> flushAll({int maxFailures = 6}) async {
    var failures = 0;
    while (true) {
      final result = await pump();
      if (result.ok) return;
      if (result.sent > 0) failures = 0;
      failures++;
      final error = result.error!;
      if (!error.retryable || failures >= maxFailures) throw error;
      await _delay(backoffFor(failures));
    }
  }
}
