/// The privacy notice shown before a Surveyor's first survey (FR-22).
///
/// It follows REQUIREMENTS.md section 9 and what the app and API really do:
/// keep the two in step when either changes.
const String privacyNoticeVersion = 'Privacy notice · RA 10173';

class NoticeSection {
  const NoticeSection(this.title, this.body);

  final String title;
  final String body;
}

const List<NoticeSection> privacyNotice = [
  NoticeSection(
    'Why we ask',
    'SignalScape measures Wi-Fi coverage inside a building and turns it into '
        'a heatmap and a 3D view. To do that it has to know where you were '
        'when each measurement was taken. Your position is personal data, so '
        'under the Data Privacy Act of 2012 (RA 10173) we need your consent '
        'before your first survey.',
  ),
  NoticeSection(
    'What we collect',
    'Your account: name, email and a hashed password (never the password '
        'itself).\n\nYour surveys: the Wi-Fi networks your phone sees (network '
        'name, BSSID, signal strength, frequency and time), your steps and '
        'compass heading, whether the phone has a barometer, the GPS fix at '
        'the start and at checkpoints, and the positions in the building '
        'worked out from them. Together these show where you walked and '
        'when. Air pressure is only used on the phone to tell floors apart; '
        'it is not uploaded.',
  ),
  NoticeSection(
    'When location is used',
    'Only while you are running a survey: one GPS fix at the start, then '
        'estimated positions inside the building, with GPS again at '
        'checkpoints. Nothing is collected before you start or after you end '
        'a survey, and the app does not track you in the background.',
  ),
  NoticeSection(
    "What we don't collect",
    'No contacts, photos, files, browsing history or advertising ID, and no '
        'device identifiers beyond what signing in needs.',
  ),
  NoticeSection(
    'Who can see it',
    'You, and administrators of this SignalScape server. Other people see a '
        'survey only if you share it with them, as a Viewer. Access is '
        'checked by role on the server.',
  ),
  NoticeSection(
    'How it is protected',
    'Passwords are hashed. Data travels over HTTPS. If the phone is offline, '
        'readings wait on the phone and upload when it is back online.',
  ),
  NoticeSection(
    'Your rights',
    'You can view, export and delete your data. Deleting a survey or your '
        'account removes its readings, results and uploaded floor plans. '
        'The in-app screen for this is not built yet; until it is, ask the '
        'administrator who runs your SignalScape server.',
  ),
  NoticeSection(
    'Where to survey',
    'Wi-Fi network names and BSSIDs belong to the building they are in. Only '
        'run a survey where you are allowed to.',
  ),
  NoticeSection(
    'Saying no',
    'You can say no. You will be signed out and no survey will start. '
        'You can agree later.',
  ),
];
