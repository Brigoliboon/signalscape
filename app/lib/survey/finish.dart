import '../core/sync_engine.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';

/// Ends a survey: lets held readings go, uploads what is left, marks the
/// survey completed, processes it and forgets the unfinished-survey note.
/// Throws [SyncException] or [ApiException] if it cannot finish, and can be
/// called again.
Future<void> finishSurvey({
  required ApiClient api,
  required LocalDb db,
  required SyncEngine engine,
  required String surveyId,
}) async {
  await db.releaseHeld(surveyId);
  await engine.flushAll();
  await api.setSurveyStatus(surveyId, 'completed');
  await api.process(surveyId);
  await db.clearActive();
}
