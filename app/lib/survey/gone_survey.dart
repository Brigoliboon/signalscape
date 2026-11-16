/// Copy and checks for a local unfinished survey whose floor, building or
/// survey record has been deleted on the server.
library;

import '../data/active_survey.dart';
import '../data/api_client.dart';

/// Title of the dialog that offers to discard the local survey.
const String localSurveyGoneTitle = 'This survey can no longer continue';

/// Explains why the local survey cannot be resumed or uploaded.
const String localSurveyGoneMessage =
    'The floor or building this survey was on has been deleted. '
    'Readings saved on this phone can no longer be uploaded. '
    'You can discard the local survey.';

/// Toast after the local survey has been forgotten.
const String localSurveyDiscardedMessage = 'The local survey was discarded.';

/// Whether an HTTP status means the survey (or its building) is gone.
bool isGoneStatus(int? statusCode) => statusCode == 404;

/// True when the building is gone (404) or the survey's floor is no longer
/// in the building. Network and other errors return false, so an offline
/// phone still offers Resume and End.
Future<bool> localSurveyTargetGone(ApiClient api, ActiveSurvey a) async {
  try {
    final b = await api.building(a.buildingId);
    return !b.floors.any((f) => f.id == a.floorId);
  } on ApiException catch (e) {
    return isGoneStatus(e.statusCode);
  } catch (_) {
    return false;
  }
}
