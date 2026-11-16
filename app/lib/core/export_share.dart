import 'dart:typed_data';

import 'package:share_plus/share_plus.dart';

/// Hands a file to the phone's share sheet (save to Files or Drive, send by
/// email or chat). Tests pass their own, so no plugin is involved.
typedef FileSharer =
    Future<void> Function({
      required String name,
      required String mimeType,
      required List<int> bytes,
    });

Future<void> shareFileWithPlugin({
  required String name,
  required String mimeType,
  required List<int> bytes,
}) async {
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile.fromData(Uint8List.fromList(bytes), mimeType: mimeType)],
      fileNameOverrides: [name],
      subject: name,
    ),
  );
}

/// `signalscape-survey-1a2b3c4d.csv` from a survey id.
String exportFileName(String surveyId, String extension) {
  final short = surveyId.replaceAll('-', '');
  final id = short.length > 8 ? short.substring(0, 8) : short;
  return 'signalscape-survey-$id.$extension';
}
