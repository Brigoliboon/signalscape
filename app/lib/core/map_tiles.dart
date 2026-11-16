import '../config.dart';

/// The looks the 2D map can have when the build has a Mapbox token.
enum MapStyle {
  satellite('Satellite', mapboxStyle),
  streetsLight('Streets light', 'light-v11'),
  streetsDark('Streets dark', 'dark-v11');

  const MapStyle(this.label, this.mapboxId);

  /// What the picker shows.
  final String label;

  /// The Mapbox style the tiles are drawn from.
  final String mapboxId;
}

/// The look the person picked last, kept while the app runs so switching
/// between the 2D map and the 3D view does not reset it.
abstract final class MapStylePreference {
  static MapStyle current = MapStyle.satellite;
}

/// Where the 2D map gets its tiles and what it has to credit (FR-16a).
///
/// With a Mapbox token the map shows satellite imagery (or a light or dark street map) from
/// Mapbox's raster style tiles (512 px tiles, so the zoom is offset by one).
/// Without one it falls back to the public OpenStreetMap street map. Esri's
/// World Imagery is not used as a free satellite fallback: its public tile
/// endpoint needs an ArcGIS licence and is not for general app use.
class MapTiles {
  const MapTiles({
    required this.urlTemplate,
    required this.attribution,
    required this.tileDimension,
    required this.zoomOffset,
    required this.maxNativeZoom,
    required this.usesMapbox,
    this.additionalOptions = const {},
  });

  factory MapTiles.forToken(String token, {String style = mapboxStyle}) =>
      token.trim().isEmpty
      ? const MapTiles(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          attribution: '© OpenStreetMap contributors',
          tileDimension: 256,
          zoomOffset: 0,
          maxNativeZoom: 19,
          usesMapbox: false,
        )
      : MapTiles(
          urlTemplate:
              'https://api.mapbox.com/styles/v1/mapbox/$style/tiles/512/'
              '{z}/{x}/{y}?access_token={accessToken}',
          attribution: '© Mapbox © OpenStreetMap contributors',
          tileDimension: 512,
          zoomOffset: -1,
          maxNativeZoom: 22,
          usesMapbox: true,
          additionalOptions: {'accessToken': token.trim()},
        );

  /// The tiles for the token this build was made with, in [style].
  factory MapTiles.current([MapStyle style = MapStyle.satellite]) =>
      MapTiles.forToken(mapboxToken, style: style.mapboxId);

  /// The same tiles in another [style]. Without Mapbox there is only the one
  /// street map, so it comes back unchanged.
  MapTiles withStyle(MapStyle style) => usesMapbox
      ? MapTiles.forToken(
          additionalOptions['accessToken'] ?? '',
          style: style.mapboxId,
        )
      : this;

  final String urlTemplate;
  final String attribution;
  final int tileDimension;
  final double zoomOffset;
  final int maxNativeZoom;
  final bool usesMapbox;
  final Map<String, String> additionalOptions;
}
