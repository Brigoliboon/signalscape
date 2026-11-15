import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/sync_engine.dart';

/// Local sqflite queue. Every reading and checkpoint is stored here first,
/// keyed by its phone-generated `client_id`, with `synced = 0` until the API
/// confirms it.
class LocalDb implements SyncStore {
  LocalDb._(this._db);

  final Database _db;

  static Future<LocalDb> open() async {
    final path = p.join(await getDatabasesPath(), 'signalscape_queue.db');
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        for (final table in const ['readings', 'checkpoints']) {
          await db.execute('''
            CREATE TABLE $table (
              client_id TEXT PRIMARY KEY,
              survey_id TEXT NOT NULL,
              body TEXT NOT NULL,
              synced INTEGER NOT NULL DEFAULT 0,
              created_ms INTEGER NOT NULL
            )''');
          await db.execute(
            'CREATE INDEX ${table}_pending ON $table (synced, survey_id)',
          );
        }
      },
    );
    return LocalDb._(db);
  }

  static String _table(SyncKind kind) =>
      kind == SyncKind.readings ? 'readings' : 'checkpoints';

  Future<void> add(
    SyncKind kind,
    String surveyId,
    Map<String, dynamic> body,
  ) async {
    await _db.insert(_table(kind), {
      'client_id': body['client_id'] as String,
      'survey_id': surveyId,
      'body': jsonEncode(body),
      'synced': 0,
      'created_ms': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<PendingBatch?> nextBatch(int limit) async {
    // Checkpoints first: there are few, and they are cheap to send.
    for (final kind in const [SyncKind.checkpoints, SyncKind.readings]) {
      final table = _table(kind);
      final first = await _db.query(
        table,
        columns: ['survey_id'],
        where: 'synced = 0',
        orderBy: 'created_ms',
        limit: 1,
      );
      if (first.isEmpty) continue;
      final surveyId = first.first['survey_id'] as String;
      final rows = await _db.query(
        table,
        where: 'synced = 0 AND survey_id = ?',
        whereArgs: [surveyId],
        orderBy: 'created_ms',
        limit: limit,
      );
      return PendingBatch(
        surveyId: surveyId,
        kind: kind,
        ids: [for (final r in rows) r['client_id'] as String],
        items: [
          for (final r in rows)
            jsonDecode(r['body'] as String) as Map<String, dynamic>,
        ],
      );
    }
    return null;
  }

  @override
  Future<void> markSynced(PendingBatch batch) async {
    final marks = List.filled(batch.ids.length, '?').join(',');
    await _db.rawUpdate(
      'UPDATE ${_table(batch.kind)} SET synced = 1 WHERE client_id IN ($marks)',
      batch.ids,
    );
  }

  @override
  Future<int> pendingCount({String? surveyId}) async {
    var total = 0;
    for (final table in const ['readings', 'checkpoints']) {
      final rows = await _db.rawQuery(
        'SELECT COUNT(*) AS n FROM $table WHERE synced = 0'
        '${surveyId == null ? '' : ' AND survey_id = ?'}',
        [?surveyId],
      );
      total += (rows.first['n'] as int?) ?? 0;
    }
    return total;
  }
}
