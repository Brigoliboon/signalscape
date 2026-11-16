import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/drift.dart';
import '../core/geo.dart';
import '../core/sync_engine.dart';
import 'active_survey.dart';

/// Local sqflite queue. Every reading and checkpoint is stored here first,
/// keyed by its phone-generated `client_id`, with `synced = 0` until the API
/// confirms it.
///
/// Readings are held back (`held = 1`) until the next checkpoint, so the drift
/// found there can be spread over them before they leave the phone (FR-10).
/// They are released uncorrected when no checkpoint comes in time.
class LocalDb implements SyncStore {
  LocalDb._(this._db);

  final Database _db;

  /// A database with no file behind it, for tests.
  static Future<LocalDb> openIn(String path) =>
      _open(path, singleInstance: false);

  static Future<LocalDb> open() async =>
      _open(p.join(await getDatabasesPath(), 'signalscape_queue.db'));

  static Future<LocalDb> _open(
    String path, {
    bool singleInstance = true,
  }) async {
    final db = await openDatabase(
      path,
      singleInstance: singleInstance,
      version: 2,
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('ALTER TABLE readings ADD COLUMN x REAL');
          await db.execute('ALTER TABLE readings ADD COLUMN y REAL');
          await db.execute(
            'ALTER TABLE readings ADD COLUMN prog REAL NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE readings ADD COLUMN held INTEGER NOT NULL DEFAULT 0',
          );
          await _createActive(db);
        }
      },
      onCreate: (db, _) async {
        for (final table in const ['readings', 'checkpoints']) {
          await db.execute('''
            CREATE TABLE $table (
              client_id TEXT PRIMARY KEY,
              survey_id TEXT NOT NULL,
              body TEXT NOT NULL,
              synced INTEGER NOT NULL DEFAULT 0,
              created_ms INTEGER NOT NULL
              ${table == 'readings' ? ', x REAL, y REAL, prog REAL NOT NULL DEFAULT 0, held INTEGER NOT NULL DEFAULT 0' : ''}
            )''');
          await db.execute(
            'CREATE INDEX ${table}_pending ON $table (synced, survey_id)',
          );
        }
        await _createActive(db);
      },
    );
    return LocalDb._(db);
  }

  static Future<void> _createActive(Database db) => db.execute('''
    CREATE TABLE active_survey (
      id INTEGER PRIMARY KEY,
      survey_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      building_id TEXT NOT NULL,
      building_name TEXT NOT NULL,
      floor_id TEXT NOT NULL,
      origin_lat REAL NOT NULL,
      origin_lng REAL NOT NULL,
      x REAL NOT NULL,
      y REAL NOT NULL,
      steps INTEGER NOT NULL,
      checkpoint_steps INTEGER NOT NULL,
      started_ms INTEGER NOT NULL,
      readings INTEGER NOT NULL,
      checkpoints INTEGER NOT NULL
    )''');

  Future<void> close() => _db.close();

  static String _table(SyncKind kind) =>
      kind == SyncKind.readings ? 'readings' : 'checkpoints';

  /// Stores a reading or checkpoint. A reading that carries its position in
  /// metres ([x], [y]) and walk [progress] is held back until [applyCorrection]
  /// or [releaseHeld] lets it go.
  Future<void> add(
    SyncKind kind,
    String surveyId,
    Map<String, dynamic> body, {
    double? x,
    double? y,
    double progress = 0,
  }) async {
    final hold = kind == SyncKind.readings && x != null && y != null;
    await _db.insert(_table(kind), {
      'client_id': body['client_id'] as String,
      'survey_id': surveyId,
      'body': jsonEncode(body),
      'synced': 0,
      'created_ms': DateTime.now().millisecondsSinceEpoch,
      if (kind == SyncKind.readings) ...{
        'x': x,
        'y': y,
        'prog': progress,
        'held': hold ? 1 : 0,
      },
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Readings waiting for a checkpoint.
  Future<int> heldCount(String surveyId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM readings WHERE held = 1 AND survey_id = ?',
      [surveyId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// Spreads a checkpoint's error over the held readings and releases them.
  /// Returns how many were corrected.
  Future<int> applyCorrection(
    String surveyId, {
    required double errX,
    required double errY,
    required double startProgress,
    required double endProgress,
    required double originLat,
    required double originLng,
  }) async {
    return _db.transaction((txn) async {
      final rows = await txn.query(
        'readings',
        where: 'held = 1 AND survey_id = ?',
        whereArgs: [surveyId],
        orderBy: 'created_ms',
      );
      final fixed = spreadDrift(
        [
          for (final r in rows)
            DriftPoint(
              (r['x'] as num).toDouble(),
              (r['y'] as num).toDouble(),
              (r['prog'] as num).toDouble(),
            ),
        ],
        errX,
        errY,
        startProgress: startProgress,
        endProgress: endProgress,
      );
      final batch = txn.batch();
      for (var i = 0; i < rows.length; i++) {
        final body =
            jsonDecode(rows[i]['body'] as String) as Map<String, dynamic>;
        final geo = toGeo(fixed[i].x, fixed[i].y, originLat, originLng);
        body['lat'] = geo.lat;
        body['lng'] = geo.lng;
        batch.update(
          'readings',
          {'body': jsonEncode(body), 'held': 0},
          where: 'client_id = ?',
          whereArgs: [rows[i]['client_id']],
        );
      }
      await batch.commit(noResult: true);
      return rows.length;
    });
  }

  /// Lets held readings go as they are. With [olderThan], only the readings
  /// held longer than that.
  Future<int> releaseHeld(String surveyId, {Duration? olderThan}) {
    final cutoff = olderThan == null
        ? DateTime.now().millisecondsSinceEpoch + 1
        : DateTime.now().millisecondsSinceEpoch - olderThan.inMilliseconds;
    return _db.update(
      'readings',
      {'held': 0},
      where: 'held = 1 AND survey_id = ? AND created_ms <= ?',
      whereArgs: [surveyId, cutoff],
    );
  }

  Future<int> readingCount(String surveyId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM readings WHERE survey_id = ?',
      [surveyId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  // --- the unfinished survey ---

  Future<void> saveActive(ActiveSurvey a) => _db.insert(
    'active_survey',
    a.toRow(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  /// The survey this user left unfinished, if any.
  Future<ActiveSurvey?> activeFor(String userId) async {
    final rows = await _db.query(
      'active_survey',
      where: 'user_id = ?',
      whereArgs: [userId],
    );
    return rows.isEmpty ? null : ActiveSurvey.fromRow(rows.first);
  }

  Future<void> clearActive() => _db.delete('active_survey');

  /// Forgets everything kept on the phone: held and waiting readings and
  /// checkpoints, and the unfinished-survey note. Used when an account is
  /// deleted.
  Future<void> clearAll() async {
    await _db.delete('readings');
    await _db.delete('checkpoints');
    await _db.delete('active_survey');
  }

  @override
  Future<PendingBatch?> nextBatch(int limit) async {
    // Checkpoints first: there are few, and they are cheap to send.
    for (final kind in const [SyncKind.checkpoints, SyncKind.readings]) {
      final table = _table(kind);
      final first = await _db.query(
        table,
        columns: ['survey_id'],
        where: 'synced = 0${kind == SyncKind.readings ? ' AND held = 0' : ''}',
        orderBy: 'created_ms',
        limit: 1,
      );
      if (first.isEmpty) continue;
      final surveyId = first.first['survey_id'] as String;
      final rows = await _db.query(
        table,
        where:
            'synced = 0 AND survey_id = ?'
            '${kind == SyncKind.readings ? ' AND held = 0' : ''}',
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
        '${table == 'readings' ? ' AND held = 0' : ''}'
        '${surveyId == null ? '' : ' AND survey_id = ?'}',
        [?surveyId],
      );
      total += (rows.first['n'] as int?) ?? 0;
    }
    return total;
  }
}
