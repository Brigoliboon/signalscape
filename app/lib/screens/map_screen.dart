import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/heatmap.dart';
import '../core/levels.dart';
import '../core/map_data.dart';
import '../core/map_tiles.dart';
import '../core/zones.dart';
import '../data/api_client.dart';
import '../theme.dart';
import '../widgets/view_switch.dart';
import 'survey_summary_screen.dart';

enum _Stage { loading, ready, empty, notProcessed, failed }

/// Draws a heatmap picture. The default does the work in an isolate; tests pass
/// one that answers at once.
typedef HeatRenderer = Future<HeatImage> Function(HeatRequest request);

Future<HeatImage> _renderInIsolate(HeatRequest request) =>
    compute(renderHeatPng, request);

/// The coverage of a processed survey on a map (FR-16a): a smooth colour
/// field with contour lines, estimated access points and the walked trail, one
/// floor at a time. The field is one picture made from the floor's grid (see
/// `core/heatmap.dart`) with an opacity slider, a minimum-signal slider and a
/// contour switch. Tiles come from Mapbox when the build has a token, else
/// OpenStreetMap.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.api,
    required this.surveyId,
    this.canProcess = false,
    this.tiles,
    this.tileProvider,
    this.onOpen3d,
    this.heatRenderer,
  });

  final ApiClient api;
  final String surveyId;

  /// Surveyors and Admins can start processing a survey that has none yet.
  final bool canProcess;

  /// Defaults to [MapTiles.current]; tests pass their own.
  final MapTiles? tiles;

  /// Defaults to the network; tests pass one that loads nothing.
  final TileProvider? tileProvider;

  /// When set, the app bar offers a switch to the 3D view.
  final void Function(BuildContext context)? onOpen3d;

  /// Defaults to an isolate; tests pass their own.
  final HeatRenderer? heatRenderer;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _map = MapController();
  late final MapTiles _baseTiles = widget.tiles ?? MapTiles.current();
  MapStyle _style = MapStylePreference.current;
  MapTiles get _tiles => _baseTiles.withStyle(_style);

  /// Null until the person taps the legend; then it follows the screen size
  /// (collapsed on a phone, open on a tablet).
  bool? _legendChoice;

  _Stage _stage = _Stage.loading;
  String? _message;
  bool _offline = false;
  bool _processing = false;
  SurveyMapData? _data;
  Map<String, dynamic>? _summary;
  Map<String, dynamic>? _trail;
  List<MapNetwork> _networks = const [];

  /// The network shown, or null for the strongest signal of any network.
  String? _bssid;
  bool _networkLoading = false;
  int? _level;
  bool _showCells = true;
  bool _showAps = true;
  bool _showTrail = true;

  /// The dead and weak zone layer (FR-26), on top of or instead of the heatmap.
  bool _showZones = false;
  final Map<String, HeatImage?> _zoneCache = {};

  // How the heatmap is drawn. The opacity is set on the overlay and redraws
  // nothing; the minimum signal and the contour lines make a new picture.
  double _opacity = 0.85;
  double _minRssi = rampWeakDbm.toDouble();
  bool _contours = true;
  late final HeatRenderer _renderer = widget.heatRenderer ?? _renderInIsolate;

  /// Pictures made so far, by floor, network and settings, newest last.
  final Map<String, HeatImage> _heatCache = {};
  int _epoch = 0; // changes whenever the grids are read again
  ({int epoch, int level, HeatImage image})? _heatShown;

  /// What the last tap on the map found, as text for the panel.
  String? _cellInfo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  FloorLayer? get _floor {
    final level = _level;
    return level == null ? null : _data?.floorAt(level);
  }

  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _message = null;
      _offline = false;
    });
    try {
      // The summary says "not processed yet" with a 409, before anything else.
      final summary = await widget.api.surveySummary(widget.surveyId);
      final geojson = await widget.api.surveyGeoJson(widget.surveyId);
      Map<String, dynamic>? trail;
      try {
        trail = await widget.api.surveyTrail(widget.surveyId);
      } on ApiException {
        // The coverage still shows without the walk.
      }
      var networks = const <MapNetwork>[];
      try {
        networks = parseNetworks(
          await widget.api.surveyNetworks(widget.surveyId),
        );
      } on ApiException {
        // Without the list the map still shows the strongest signal.
      }
      if (!mounted) return;
      final data = SurveyMapData.parse(
        geojson: geojson,
        trail: trail,
        summary: summary,
      );
      setState(() {
        _summary = summary;
        _trail = trail;
        _networks = networks;
        _bssid = null;
        _data = data;
        _epoch++;
        _cellInfo = null;
        _level = data.initialFloor?.level;
        _stage = data.isEmpty ? _Stage.empty : _Stage.ready;
      });
      _requestHeat();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _offline = e.isNetwork;
        _message = e.message;
        _stage = e.statusCode == 409 ? _Stage.notProcessed : _Stage.failed;
      });
    }
  }

  Future<void> _processNow() async {
    setState(() => _processing = true);
    try {
      await widget.api.process(widget.surveyId);
      if (!mounted) return;
      setState(() => _processing = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _message = e.message;
      });
    }
  }

  CameraFit? _fitFor(FloorLayer? floor) {
    final b = floor == null ? null : boundsOf(floor);
    if (b == null) return null;
    return CameraFit.coordinates(
      coordinates: [b.sw, b.ne],
      padding: const EdgeInsets.fromLTRB(32, 176, 32, 96),
      maxZoom: 21,
    );
  }

  /// Shows one network (or, with null, the strongest signal) on every floor.
  /// The walk and floor names stay as they are; the cells and access points
  /// are read again for that network.
  Future<void> _pickNetwork(String? bssid) async {
    if (bssid == _bssid || _networkLoading) return;
    setState(() => _networkLoading = true);
    try {
      final geojson = await widget.api.surveyGeoJson(
        widget.surveyId,
        bssid: bssid,
      );
      if (!mounted) return;
      final data = SurveyMapData.parse(
        geojson: geojson,
        trail: _trail,
        summary: _summary,
      );
      setState(() {
        _bssid = bssid;
        _data = data;
        _epoch++;
        _cellInfo = null;
        if (data.floorAt(_level ?? -9999) == null) {
          _level = data.initialFloor?.level;
        }
        _networkLoading = false;
      });
      _requestHeat();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _networkLoading = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              e.isNetwork
                  ? "You're offline. The network was not changed."
                  : "Couldn't load that network: ${e.message}",
            ),
          ),
        );
    }
  }

  void _pickFloor(int level) {
    setState(() {
      _level = level;
      _cellInfo = null;
    });
    final fit = _fitFor(_floor);
    if (fit != null) _map.fitCamera(fit);
    _requestHeat();
  }

  String _heatKey(FloorLayer floor) =>
      '$_epoch|${floor.level}|${_minRssi.round()}|$_contours';

  /// Makes the picture for the floor on show, unless it is already made.
  void _requestHeat() {
    final floor = _floor;
    final heat = floor?.heat;
    if (floor == null || heat == null) return;
    final key = _heatKey(floor);
    final epoch = _epoch;
    final level = floor.level;
    final cached = _heatCache[key];
    if (cached != null) {
      setState(() => _heatShown = (epoch: epoch, level: level, image: cached));
      return;
    }
    _renderer(
      HeatRequest(grid: heat.grid, minRssi: _minRssi, contours: _contours),
    ).then<void>(
      (image) {
        if (!mounted) return;
        setState(() {
          _heatCache[key] = image;
          while (_heatCache.length > 8) {
            _heatCache.remove(_heatCache.keys.first);
          }
          // A picture for a floor or network that is no longer on show is kept
          // for later but not shown.
          if (epoch == _epoch && level == _level) {
            _heatShown = (epoch: epoch, level: level, image: image);
          }
        });
      },
      onError: (Object _) {
        // No picture: the map still shows everything else.
      },
    );
  }

  /// The picture for [floor]: the one for the current settings, else the last
  /// one for this floor while the new one is made.
  HeatImage? _heatImageFor(FloorLayer floor) {
    final exact = _heatCache[_heatKey(floor)];
    if (exact != null) return exact;
    final shown = _heatShown;
    return shown != null && shown.epoch == _epoch && shown.level == floor.level
        ? shown.image
        : null;
  }

  Thresholds get _thresholds => _data?.thresholds ?? const Thresholds();

  /// The zone picture of [floor] with the thresholds in force, made once per
  /// floor, network, grid read and thresholds.
  HeatImage? _zonesImageFor(FloorLayer floor) {
    final heat = floor.heat;
    if (heat == null) return null;
    final t = _thresholds;
    final key =
        '$_epoch|${floor.level}|${_bssid ?? ''}|${t.goodDbm}|${t.deadDbm}';
    _zoneCache.removeWhere((k, _) => !k.startsWith('$_epoch|'));
    return _zoneCache.putIfAbsent(key, () => renderZonesPng(heat.grid, t));
  }

  /// A tap on the map: the value of the nearest cell of the floor on show.
  void _tapMap(LatLng at) {
    final floor = _floor;
    final heat = floor?.heat;
    if ((!_showCells && !_showZones) || heat == null) return;
    final cell = heat.nearestCell(at);
    final value = cell.value;
    final t = _data?.thresholds ?? const Thresholds();
    setState(() {
      _cellInfo = value == null
          ? 'No data here (no reading within 5 m)'
          : '${value.round()} dBm · ${levelName(levelFor(value, t))}'
                ' · nearest cell';
    });
  }

  void _showAccessPoint(MapAccessPoint ap) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ap.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('BSSID ${ap.bssid}', style: mono(size: 14)),
              const SizedBox(height: 4),
              Text(
                ap.confidenceText,
                key: const ValueKey('ap-confidence'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                'Strongest reading ${ap.rssiDbm} dBm',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Coverage'),
        actions: [
          IconButton(
            key: const ValueKey('open-summary'),
            tooltip: 'Summary and export',
            icon: const Icon(Icons.summarize_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => SurveySummaryScreen(
                  api: widget.api,
                  surveyId: widget.surveyId,
                  canProcess: widget.canProcess,
                ),
              ),
            ),
          ),
          if (widget.onOpen3d != null)
            ViewSwitch(is3d: false, onSwitch: () => widget.onOpen3d!(context)),
        ],
      ),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.ready => _mapBody(),
          _ => _notice(),
        },
      ),
    );
  }

  Widget _notice() {
    final (String title, String body) = switch (_stage) {
      _Stage.notProcessed => (
        'Not processed yet',
        widget.canProcess
            ? 'This survey has no coverage results yet. Process it to see '
                  'the map.'
            : 'This survey has no coverage results yet. Ask the surveyor to '
                  'finish and process it.',
      ),
      _Stage.empty => (
        'Nothing to show',
        'This survey has no coverage cells, access points or walk to draw.',
      ),
      _ => (
        _offline ? "You're offline" : "Couldn't load the map",
        _offline
            ? 'The map needs a connection to load the results. Check your '
                  'connection and try again.'
            : (_message ?? 'Something went wrong.'),
      ),
    };
    final canProcess = _stage == _Stage.notProcessed && widget.canProcess;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            if (canProcess && _message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, textAlign: TextAlign.center),
            ],
            const SizedBox(height: 16),
            if (canProcess)
              FilledButton(
                onPressed: _processing ? null : _processNow,
                child: Text(_processing ? 'Processing…' : 'Process now'),
              )
            else if (_stage != _Stage.empty)
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }

  Widget _mapBody() {
    final data = _data!;
    final floor = _floor!;
    final tiles = _tiles;
    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            backgroundColor: AppColors.background,
            initialCenter: const LatLng(0, 0),
            initialZoom: 2,
            initialCameraFit: _fitFor(floor),
            maxZoom: 22,
            onTap: (_, at) => _tapMap(at),
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              key: ValueKey('tiles-${_style.name}'),
              urlTemplate: tiles.urlTemplate,
              additionalOptions: tiles.additionalOptions,
              tileDimension: tiles.tileDimension,
              zoomOffset: tiles.zoomOffset,
              maxNativeZoom: tiles.maxNativeZoom,
              userAgentPackageName: mapUserAgentPackage,
              tileProvider: widget.tileProvider,
            ),
            if (_showCells &&
                floor.heat != null &&
                _heatImageFor(floor) != null)
              OverlayImageLayer(
                key: ValueKey('heat-${floor.level}'),
                overlayImages: [
                  OverlayImage(
                    bounds: LatLngBounds(
                      floor.heat!.pictureSouthWest,
                      floor.heat!.pictureNorthEast,
                    ),
                    imageProvider: MemoryImage(_heatImageFor(floor)!.png),
                    opacity: _opacity,
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.medium,
                  ),
                ],
              ),
            if (_showZones && _zonesImageFor(floor) != null)
              OverlayImageLayer(
                key: ValueKey('zones-${floor.level}'),
                overlayImages: [
                  OverlayImage(
                    bounds: LatLngBounds(
                      floor.heat!.pictureSouthWest,
                      floor.heat!.pictureNorthEast,
                    ),
                    imageProvider: MemoryImage(_zonesImageFor(floor)!.png),
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.none,
                  ),
                ],
              ),
            if (_showTrail && floor.trail.length > 1)
              PolylineLayer(
                key: ValueKey('trail-${floor.level}'),
                simplificationTolerance: 0,
                polylines: [
                  Polyline(
                    points: floor.trail,
                    strokeWidth: 3.5,
                    color: Colors.white,
                    // A dark casing keeps the white line visible on roofs.
                    borderStrokeWidth: 2.5,
                    borderColor: Colors.black.withValues(alpha: 0.85),
                  ),
                ],
              ),
            if (_showTrail)
              MarkerLayer(
                markers: [
                  if (floor.start != null)
                    _pin(
                      floor.start!,
                      'S',
                      AppColors.good,
                      'Start of the walk',
                    ),
                  if (floor.end != null)
                    _pin(floor.end!, 'E', AppColors.dead, 'End of the walk'),
                ],
              ),
            if (_showAps)
              MarkerLayer(
                markers: [
                  for (final ap in floor.accessPoints)
                    Marker(
                      point: ap.at,
                      width: kTarget,
                      height: kTarget,
                      child: Semantics(
                        key: ValueKey('ap-${ap.bssid}'),
                        button: true,
                        label: ap.lowConfidence
                            ? 'Access point ${ap.name}, low confidence'
                            : 'Access point ${ap.name}',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showAccessPoint(ap),
                          child: ApMarker(lowConfidence: ap.lowConfidence),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
        Positioned(left: 8, right: 8, top: 8, child: _topPanel(data, floor)),
        // Everything at the bottom is one column, so the parts cannot overlap.
        Positioned(
          left: 8,
          right: 8,
          bottom: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_cellInfo != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    key: const ValueKey('cell-info'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: _panel(radius: 12),
                    child: Text(_cellInfo!),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _legend(data.thresholds),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: _panel(radius: 6, alpha: 0.85),
                        child: Text(
                          tiles.attribution,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _toolbar(),
            ],
          ),
        ),
      ],
    );
  }

  static final List<BoxShadow> _shadow = [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.6),
      blurRadius: 4,
      spreadRadius: 1,
    ),
  ];

  Marker _pin(LatLng at, String letter, Color color, String label) => Marker(
    point: at,
    width: 32,
    height: 32,
    child: Semantics(
      key: ValueKey('pin-$letter'),
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: _shadow,
        ),
        alignment: Alignment.center,
        child: Text(
          letter,
          style: const TextStyle(
            color: AppColors.background,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );

  /// The look shared by every floating panel on the map.
  BoxDecoration _panel({double radius = 12, double alpha = 0.94}) =>
      BoxDecoration(
        color: AppColors.surface.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: AppColors.outline),
      );

  /// The top card: which floor and network are shown, and the Display and
  /// map style buttons.
  Widget _topPanel(SurveyMapData data, FloorLayer floor) {
    return Container(
      key: const ValueKey('top-panel'),
      padding: const EdgeInsets.all(8),
      decoration: _panel(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.floors.length > 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in data.floors)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('floor-${f.level}'),
                        label: Text(f.label),
                        selected: f.level == floor.level,
                        onSelected: (_) => _pickFloor(f.level),
                      ),
                    ),
                  _zonesChip(),
                ],
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  Chip(label: Text(floor.label)),
                  const SizedBox(width: 8),
                  _zonesChip(),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _networkPicker()),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('display-settings'),
                tooltip: 'Display: opacity, minimum signal, contour lines',
                icon: const Icon(Icons.tune),
                onPressed: _showDisplaySettings,
              ),
              IconButton(
                key: const ValueKey('map-style'),
                tooltip: _tiles.usesMapbox
                    ? 'Map style: ${_style.label}'
                    : 'Map style: street map',
                icon: const Icon(Icons.layers_outlined),
                onPressed: _showStylePicker,
              ),
            ],
          ),
          if (_noDataHere(floor))
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'No readings of this network on this floor.',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  /// Next to the floor filter: the dead and weak zone layer (FR-26).
  Widget _zonesChip() => FilterChip(
    key: const ValueKey('layer-zones'),
    avatar: const Icon(Icons.signal_wifi_bad, size: 18),
    label: const Text('Dead & weak zones'),
    selected: _showZones,
    onSelected: (v) => setState(() => _showZones = v),
  );

  /// The bottom card: which layers are drawn.
  Widget _toolbar() {
    return Container(
      key: const ValueKey('toolbar'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: _panel(),
      child: Wrap(
        spacing: 8,
        runSpacing: 0,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilterChip(
            key: const ValueKey('layer-cells'),
            label: const Text('Coverage'),
            selected: _showCells,
            onSelected: (v) => setState(() => _showCells = v),
          ),
          FilterChip(
            key: const ValueKey('layer-aps'),
            label: const Text('Access points'),
            selected: _showAps,
            onSelected: (v) => setState(() => _showAps = v),
          ),
          FilterChip(
            key: const ValueKey('layer-trail'),
            label: const Text('Walk'),
            selected: _showTrail,
            onSelected: (v) => setState(() => _showTrail = v),
          ),
        ],
      ),
    );
  }

  /// Satellite, streets light or streets dark. Without a Mapbox token there is
  /// only the OpenStreetMap street map, so the choices are off and say why.
  void _showStylePicker() {
    final mapbox = _baseTiles.usesMapbox;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Map style',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              if (!mapbox)
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text(
                    'Styles need a Mapbox token. This build shows the '
                    'OpenStreetMap street map.',
                    key: ValueKey('style-note'),
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              for (final style in MapStyle.values)
                ListTile(
                  key: ValueKey('style-${style.name}'),
                  enabled: mapbox,
                  leading: Icon(switch (style) {
                    MapStyle.satellite => Icons.satellite_alt_outlined,
                    MapStyle.streetsLight => Icons.light_mode_outlined,
                    MapStyle.streetsDark => Icons.dark_mode_outlined,
                  }),
                  title: Text(style.label),
                  trailing: mapbox && style == _style
                      ? const Icon(Icons.check, color: AppColors.accent)
                      : null,
                  selected: mapbox && style == _style,
                  onTap: () {
                    MapStylePreference.current = style;
                    setState(() => _style = style);
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  bool _noDataHere(FloorLayer floor) =>
      _bssid != null && floor.cells.isEmpty && floor.accessPoints.isEmpty;

  /// The same choice as the 3D view's network list: the strongest signal of
  /// any network, or one network by SSID and BSSID.
  Widget _networkPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                key: const ValueKey('network-picker'),
                isExpanded: true,
                value: _bssid,
                dropdownColor: AppColors.surfaceHigh,
                hint: const Text('Network'),
                onChanged: _networkLoading ? null : _pickNetwork,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All networks (strongest signal)'),
                  ),
                  for (final n in _networks)
                    DropdownMenuItem<String?>(
                      value: n.bssid,
                      child: Text(
                        '${n.label} (${n.readingCount})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_networkLoading)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
    );
  }

  /// Opacity, minimum signal and contour lines, in a bottom sheet.
  void _showDisplaySettings() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Display', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text('Opacity ${(_opacity * 100).round()}%'),
                Slider(
                  key: const ValueKey('heat-opacity'),
                  value: _opacity,
                  min: 0.1,
                  max: 1,
                  divisions: 18,
                  label: '${(_opacity * 100).round()}%',
                  onChanged: (v) {
                    setState(() => _opacity = v);
                    setSheet(() {});
                  },
                ),
                Text('Min RSSI ${_minRssi.round()} dBm'),
                Slider(
                  key: const ValueKey('heat-min-rssi'),
                  value: _minRssi,
                  min: rampWeakDbm.toDouble(),
                  max: rampStrongDbm.toDouble(),
                  divisions: rampStrongDbm - rampWeakDbm,
                  label: '${_minRssi.round()} dBm',
                  onChanged: (v) {
                    setState(() => _minRssi = v);
                    setSheet(() {});
                  },
                  // The picture is made again once the slider is let go.
                  onChangeEnd: (_) => _requestHeat(),
                ),
                SwitchListTile(
                  key: const ValueKey('heat-contours'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Contour lines'),
                  subtitle: Text('Every $defaultContourStepDb dBm'),
                  value: _contours,
                  onChanged: (v) {
                    setState(() => _contours = v);
                    setSheet(() {});
                    _requestHeat();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The colour ramp as a gradient bar, strong on the left, with dBm ticks,
  /// then the surveyor's thresholds as text. Collapsed it is a chip with a
  /// small bar; a phone starts collapsed so it does not cover the map.
  Widget _legend(Thresholds? t) {
    final open =
        _legendChoice ?? MediaQuery.sizeOf(context).width > _wideScreenDp;
    final gradient = LinearGradient(
      colors: [for (final s in rampStops) Color.fromARGB(255, s.r, s.g, s.b)],
      stops: [for (final s in rampStops) rampFraction(s.dbm.toDouble())],
    );
    final header = Semantics(
      button: true,
      expanded: open,
      label: 'Legend',
      excludeSemantics: true,
      child: InkWell(
        key: const ValueKey('legend-toggle'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _legendChoice = !open),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!open) ...[
                  Container(
                    key: const ValueKey('legend-ramp-mini'),
                    width: 56,
                    height: 10,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.black45, width: 0.5),
                      gradient: gradient,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                const Text('Legend', style: TextStyle(fontSize: 13)),
                Icon(
                  open ? Icons.expand_more : Icons.expand_less,
                  size: 20,
                  color: AppColors.textMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    const barWidth = 180.0;
    return Container(
      key: const ValueKey('legend'),
      decoration: _panel(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    key: const ValueKey('legend-ramp'),
                    width: barWidth,
                    height: 10,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.black45, width: 0.5),
                      gradient: gradient,
                    ),
                  ),
                  SizedBox(
                    width: barWidth,
                    height: 14,
                    child: Stack(
                      children: [
                        for (final tick in legendTicks)
                          Positioned(
                            // Centred on its place on the bar, but kept inside it.
                            left:
                                (rampFraction(tick.toDouble()) * barWidth - 12)
                                    .clamp(0.0, barWidth - 24),
                            width: 24,
                            child: Text(
                              '$tick',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 9,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t == null ? 'Good' : 'Good ≥ ${t.goodDbm} dBm',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    t == null ? 'Dead' : 'Dead < ${t.deadDbm} dBm',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text(
                    'Lines every $defaultContourStepDb dBm',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (_showZones) ...[
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const ZoneSwatch(dead: false),
                        const SizedBox(width: 8),
                        Text(
                          weakZoneText(_thresholds),
                          key: const ValueKey('legend-zone-weak'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const ZoneSwatch(dead: true),
                        const SizedBox(width: 8),
                        Text(
                          deadZoneText(_thresholds),
                          key: const ValueKey('legend-zone-dead'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        color: Color.fromARGB(
                          255,
                          rampStops[3].r,
                          rampStops[3].g,
                          rampStops[3].b,
                        ).withValues(alpha: confidenceAlpha(0, full: 0.75)),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Faded = few readings',
                        key: ValueKey('legend-faded'),
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ApMarker(lowConfidence: false, size: 18),
                      SizedBox(width: 6),
                      Text(
                        'Access point',
                        key: ValueKey('legend-ap'),
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ApMarker(lowConfidence: true, size: 18),
                      SizedBox(width: 6),
                      Text(
                        'Low confidence placement',
                        key: ValueKey('legend-ap-low'),
                        style: TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          header,
        ],
      ),
    );
  }
}

/// Screens wider than this (dp) start with the legend open.
const double _wideScreenDp = 600;

/// An estimated access point (FR-25). Confident: a solid blue disc. Low
/// confidence: a hollow blue ring at 40% opacity with a "?" badge, so it does
/// not rely on colour alone. Not the green, amber or red of signal levels.
class ApMarker extends StatelessWidget {
  const ApMarker({super.key, required this.lowConfidence, this.size = 32});

  final bool lowConfidence;

  /// Diameter of the disc; the tap target around it is set by the caller.
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = size * 0.56;
    if (!lowConfidence) {
      return Center(
        child: Container(
          key: const ValueKey('ap-solid'),
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: size / 16),
            boxShadow: _apShadow,
          ),
          child: Icon(Icons.wifi, size: icon, color: Colors.white),
        ),
      );
    }
    final badge = size * 0.5;
    return Center(
      child: SizedBox(
        key: const ValueKey('ap-hollow'),
        width: size + badge / 2,
        height: size + badge / 2,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              bottom: 0,
              child: Opacity(
                opacity: 0.4,
                child: Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.primary,
                      width: size / 10,
                    ),
                  ),
                  child: Icon(Icons.wifi, size: icon, color: AppColors.primary),
                ),
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: badge,
                height: badge,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.primary, width: 1),
                ),
                child: Text(
                  '?',
                  style: TextStyle(
                    fontSize: badge * 0.7,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final List<BoxShadow> _apShadow = [
  BoxShadow(
    color: Colors.black.withValues(alpha: 0.6),
    blurRadius: 4,
    spreadRadius: 1,
  ),
];

/// A legend swatch of the zone layer: amber for weak, hatched red for dead.
class ZoneSwatch extends StatelessWidget {
  const ZoneSwatch({super.key, required this.dead});

  final bool dead;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: ValueKey(dead ? 'zone-swatch-dead' : 'zone-swatch-weak'),
    size: const Size(12, 12),
    painter: _ZoneSwatchPainter(dead),
  );
}

class _ZoneSwatchPainter extends CustomPainter {
  const _ZoneSwatchPainter(this.dead);

  final bool dead;

  @override
  void paint(Canvas canvas, Size size) {
    final rgb = dead ? zoneDeadRgb : zoneWeakRgb;
    final color = Color(0xFF000000 | rgb);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: zoneAlpha),
    );
    if (!dead) return;
    final line = Paint()
      ..color = color.withValues(alpha: zoneHatchAlpha)
      ..strokeWidth = 1.5;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += 4) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ZoneSwatchPainter old) => old.dead != dead;
}
