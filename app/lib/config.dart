/// Build-time settings. Override with `--dart-define=API_BASE_URL=http://10.0.2.2:8000`.
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://signalscape.boonbrigoli.site',
);

/// Largest GPS error the API accepts for a survey's starting fix (metres).
const double maxStartAccuracyM = 10;

/// Readings and checkpoints are uploaded in batches of at most this many.
const int syncBatchSize = 500;

/// Mapbox public access token for the 2D map, set at build time with
/// `--dart-define=MAPBOX_TOKEN=pk...`. Never put a token in the code. When it
/// is empty the map falls back to OpenStreetMap tiles.
const String mapboxToken = String.fromEnvironment('MAPBOX_TOKEN');

/// Mapbox style used for the 2D map; a dark one to match the app.
const String mapboxStyle = 'dark-v11';

/// Sent to OpenStreetMap's tile server, which asks apps to identify themselves.
const String mapUserAgentPackage = 'com.example.signalscape_mobile';
