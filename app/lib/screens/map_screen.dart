import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/levels.dart';
import '../core/map_data.dart';
import '../core/map_tiles.dart';
import '../data/api_client.dart';
import '../theme.dart';

enum _Stage { loading, ready, empty, notProcessed, failed }

/// The coverage of a processed survey on a street map (FR-16a): coloured
/// cells, estimated access points and the walked trail, one floor at a time.
/// Tiles come from Mapbox when the build has a token, else OpenStreetMap.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    required this.api,
    required this.surveyId,
    this.canProcess = false,
    this.tiles,
    this.tileProvider,
    this.onOpen3d,
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

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _map = MapController();
  late final MapTiles _tiles = widget.tiles ?? MapTiles.current();

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
        _level = data.initialFloor?.level;
        _stage = data.isEmpty ? _Stage.empty : _Stage.ready;
      });
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
        if (data.floorAt(_level ?? -9999) == null) {
          _level = data.initialFloor?.level;
        }
        _networkLoading = false;
      });
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
    setState(() => _level = level);
    final fit = _fitFor(_floor);
    if (fit != null) _map.fitCamera(fit);
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
                'Strongest reading ${ap.rssiDbm} dBm, '
                'placed from ${ap.readingCount} readings',
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
        title: const Text('Coverage map'),
        actions: [
          if (widget.onOpen3d != null)
            TextButton(
              onPressed: () => widget.onOpen3d!(context),
              child: const Text('3D view'),
            ),
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
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: tiles.urlTemplate,
              additionalOptions: tiles.additionalOptions,
              tileDimension: tiles.tileDimension,
              zoomOffset: tiles.zoomOffset,
              maxNativeZoom: tiles.maxNativeZoom,
              userAgentPackageName: mapUserAgentPackage,
              tileProvider: widget.tileProvider,
            ),
            if (_showCells && floor.cells.isNotEmpty)
              PolygonLayer(
                key: ValueKey('cells-${floor.level}'),
                simplificationTolerance: 0,
                polygons: [
                  for (final c in floor.cells)
                    Polygon(
                      points: c.ring,
                      // Strong enough to read on bright imagery, with a faint
                      // edge so neighbouring cells stay apart.
                      // Faded where few readings back the cell.
                      color: levelColor(c.level).withValues(
                        alpha: confidenceAlpha(c.confidence, full: 0.75),
                      ),
                      borderColor: Colors.black.withValues(
                        alpha: confidenceAlpha(c.confidence, full: 0.3),
                      ),
                      borderStrokeWidth: 0.6,
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
                        label: 'Access point ${ap.name}',
                        child: GestureDetector(
                          onTap: () => _showAccessPoint(ap),
                          child: Container(
                            margin: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: _shadow,
                            ),
                            child: const Icon(
                              Icons.wifi,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
        Positioned(left: 8, right: 8, top: 8, child: _controls(data, floor)),
        Positioned(left: 8, bottom: 8, child: _legend(data.thresholds)),
        Positioned(
          right: 8,
          bottom: 8,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.5,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
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

  Widget _controls(SurveyMapData data, FloorLayer floor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
              ],
            ),
          )
        else
          Chip(label: Text(floor.label)),
        const SizedBox(height: 4),
        _networkPicker(),
        if (_noDataHere(floor))
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.9),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'No readings of this network on this floor.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
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
      ],
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
        color: AppColors.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
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

  Widget _legend(Thresholds? t) {
    String text(SignalLevel l) => switch (l) {
      SignalLevel.good => t == null ? 'Good' : 'Good ≥ ${t.goodDbm} dBm',
      SignalLevel.fair => 'Fair',
      SignalLevel.dead => t == null ? 'Dead' : 'Dead < ${t.deadDbm} dBm',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in SignalLevel.values)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 12, height: 12, color: levelColor(l)),
                const SizedBox(width: 8),
                Text(text(l), style: const TextStyle(fontSize: 12)),
              ],
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                color: levelColor(
                  SignalLevel.fair,
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
        ],
      ),
    );
  }
}
