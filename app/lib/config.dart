/// Build-time settings. Override with `--dart-define=API_BASE_URL=http://10.0.2.2:8000`.
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://signalscape.boonbrigoli.site',
);

/// Largest GPS error the API accepts for a survey's starting fix (metres).
const double maxStartAccuracyM = 10;

/// Readings and checkpoints are uploaded in batches of at most this many.
const int syncBatchSize = 500;
