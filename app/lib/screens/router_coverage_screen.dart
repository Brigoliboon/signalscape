import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../core/heatmap.dart';
import '../core/map_tiles.dart';
import '../core/router_data.dart';
import '../core/zones.dart';
import '../data/api_client.dart';
import '../theme.dart';
import 'map_screen.dart' show ZoneSwatch;

enum _Stage { loading, ready, empty, notProcessed, failed }

/// Router coverage mode (FR-27 to FR-29), a separate screen from the
/// strongest-signal heatmap. One floor at a time: every router (BSSIDs of one
/// radio counted once) with the network names it broadcasts, the footprint of
/// each selected router, and the chains of routers that share a name with the
/// weak and dead gaps along the links between them.
class RouterCoverageScreen extends StatefulWidget {
  const RouterCoverageScreen({
    super.key,
    required this.api,
    required this.surveyId,
    this.tiles,
    this.tileProvider,
  });

  final ApiClient api;
  final String surveyId;
  final MapTiles? tiles;
  final TileProvider? tileProvider;

  @override
  State<RouterCoverageScreen> createState() => _RouterCoverageScreenState();
}

class _RouterCoverageScreenState extends State<RouterCoverageScreen> {
  final MapController _map = MapController();
  late final MapTiles _tiles = widget.tiles ?? MapTiles.current();

  _Stage _stage = _Stage.loading;
  String? _message;
  bool _offline = false;
  RouterCoverage? _data;
  int? _level;

  /// The routers whose footprint is drawn, by id.
  final Set<String> _selected = {};
  bool _showGaps = true;
  final Map<String, HeatImage?> _pictures = {};

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

  RouterFloor? get _floor {
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
      final json = await widget.api.surveyRouters(widget.surveyId);
      if (!mounted) return;
      final data = RouterCoverage.parse(json);
      final first = data.floors.where((f) => f.routers.isNotEmpty).firstOrNull;
      setState(() {
        _data = data;
        _pictures.clear();
        _level = first?.level;
        _selectDefault(first);
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

  /// The strongest router of the floor is shown first; more can be ticked.
  void _selectDefault(RouterFloor? floor) {
    _selected.clear();
    if (floor != null && floor.routers.isNotEmpty) {
      _selected.add(floor.routers.first.id);
    }
  }

  void _pickFloor(int level) {
    setState(() {
      _level = level;
      _selectDefault(_floor);
    });
    final fit = _fitFor(_floor);
    if (fit != null) _map.fitCamera(fit);
  }

  void _toggle(MapRouter router) => setState(() {
    if (!_selected.remove(router.id)) _selected.add(router.id);
  });

  /// Shows the footprints of every router of [chain].
  void _showChain(RouterChain chain) => setState(() {
    _selected
      ..clear()
      ..addAll(chain.routerIds);
    _showGaps = true;
  });

  CameraFit? _fitFor(RouterFloor? floor) {
    if (floor == null) return null;
    final points = <LatLng>[];
    for (final r in floor.routers) {
      final f = r.footprint;
      if (f != null) points.addAll([f.pictureSouthWest, f.pictureNorthEast]);
      if (r.at != null) points.add(r.at!);
    }
    if (points.isEmpty) return null;
    return CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 24),
      maxZoom: 21,
    );
  }

  HeatImage? _footprintImage(MapRouter router) {
    final heat = router.footprint;
    if (heat == null) return null;
    final t = _data!.thresholds;
    return _pictures.putIfAbsent(
      'f|$_level|${router.id}',
      () => renderFootprintPng(heat.grid, router.rgb, t),
    );
  }

  HeatImage? _gapImage(int index, RouterChain chain) {
    final heat = chain.gaps;
    if (heat == null) return null;
    return _pictures.putIfAbsent(
      'g|$_level|$index',
      () => renderZonesPng(heat.grid, _data!.thresholds),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Router coverage')),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.ready => _body(),
          _ => _notice(),
        },
      ),
    );
  }

  Widget _notice() {
    final (String title, String body) = switch (_stage) {
      _Stage.notProcessed => (
        'Not processed yet',
        'Router coverage needs a processed survey. Process it from the map '
            'or the summary first.',
      ),
      _Stage.empty => (
        'No routers',
        'No network survived cleaning on any floor, so there is no router to '
            'show.',
      ),
      _ => (
        _offline ? "You're offline" : "Couldn't load router coverage",
        _offline
            ? 'Router coverage needs a connection. Check it and try again.'
            : (_message ?? 'Something went wrong.'),
      ),
    };
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
            if (_stage != _Stage.empty && _stage != _Stage.notProcessed) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _load, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final data = _data!;
    final floor = _floor!;
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            children: [
              _mapView(floor),
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: _floorPanel(data, floor),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(flex: 2, child: _list(data, floor)),
      ],
    );
  }

  Widget _mapView(RouterFloor floor) {
    final selected = floor.routers.where((r) => _selected.contains(r.id));
    final chains = floor.chains;
    return FlutterMap(
      key: ValueKey('router-map-${floor.level}'),
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
          urlTemplate: _tiles.urlTemplate,
          additionalOptions: _tiles.additionalOptions,
          tileDimension: _tiles.tileDimension,
          zoomOffset: _tiles.zoomOffset,
          maxNativeZoom: _tiles.maxNativeZoom,
          userAgentPackageName: mapUserAgentPackage,
          tileProvider: widget.tileProvider,
        ),
        for (final r in selected)
          if (r.footprint != null && _footprintImage(r) != null)
            OverlayImageLayer(
              key: ValueKey('footprint-${r.number}'),
              overlayImages: [
                OverlayImage(
                  bounds: LatLngBounds(
                    r.footprint!.pictureSouthWest,
                    r.footprint!.pictureNorthEast,
                  ),
                  imageProvider: MemoryImage(_footprintImage(r)!.png),
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.none,
                ),
              ],
            ),
        if (_showGaps)
          for (final (i, chain) in chains.indexed)
            if (chain.gaps != null && _gapImage(i, chain) != null)
              OverlayImageLayer(
                key: ValueKey('gaps-$i'),
                overlayImages: [
                  OverlayImage(
                    bounds: LatLngBounds(
                      chain.gaps!.pictureSouthWest,
                      chain.gaps!.pictureNorthEast,
                    ),
                    imageProvider: MemoryImage(_gapImage(i, chain)!.png),
                    gaplessPlayback: true,
                    filterQuality: FilterQuality.none,
                  ),
                ],
              ),
        PolylineLayer(
          key: const ValueKey('chain-links'),
          simplificationTolerance: 0,
          polylines: [
            for (final chain in chains)
              for (final link in chain.links)
                if (floor.routerById(link.from)?.at != null &&
                    floor.routerById(link.to)?.at != null)
                  Polyline(
                    points: [
                      floor.routerById(link.from)!.at!,
                      floor.routerById(link.to)!.at!,
                    ],
                    strokeWidth: 3,
                    color: linkColor(link.status),
                    borderStrokeWidth: 2,
                    borderColor: Colors.black.withValues(alpha: 0.8),
                    pattern: link.status == 'covered'
                        ? const StrokePattern.solid()
                        : StrokePattern.dashed(segments: const [10, 6]),
                  ),
          ],
        ),
        MarkerLayer(
          markers: [
            for (final r in floor.routers)
              if (r.at != null)
                Marker(
                  point: r.at!,
                  width: kTarget,
                  height: kTarget,
                  child: Semantics(
                    key: ValueKey('router-${r.number}'),
                    button: true,
                    label: r.lowConfidence
                        ? '${r.label}, low confidence placement'
                        : r.label,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _showRouter(r),
                      child: RouterMarker(
                        number: r.number,
                        rgb: r.rgb,
                        lowConfidence: r.lowConfidence,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }

  BoxDecoration _panel() => BoxDecoration(
    color: AppColors.surface.withValues(alpha: 0.94),
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: AppColors.outline),
  );

  Widget _floorPanel(RouterCoverage data, RouterFloor floor) {
    final floors = data.floors.where((f) => f.routers.isNotEmpty).toList();
    return Container(
      key: const ValueKey('router-floors'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: _panel(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in floors)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: ValueKey('router-floor-${f.level}'),
                  label: Text(f.label),
                  selected: f.level == floor.level,
                  onSelected: (_) => _pickFloor(f.level),
                ),
              ),
            FilterChip(
              key: const ValueKey('show-gaps'),
              avatar: const Icon(Icons.link_off, size: 18),
              label: const Text('Gaps between routers'),
              selected: _showGaps,
              onSelected: (v) => setState(() => _showGaps = v),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(RouterCoverage data, RouterFloor floor) {
    final t = data.thresholds;
    final count = floor.routers.length;
    return ListView(
      key: const ValueKey('router-list'),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${count == 1 ? '1 router' : '$count routers'} on this floor · '
            '${data.routerCount} in the survey, from ${data.bssidCount} '
            'BSSIDs',
            key: const ValueKey('router-count'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'One radio that serves several network names counts once. Tick a '
            'router to see its footprint.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ),
        for (final r in floor.routers)
          CheckboxListTile(
            key: ValueKey('router-tile-${r.number}'),
            value: _selected.contains(r.id),
            onChanged: (_) => _toggle(r),
            secondary: RouterSwatch(number: r.number, rgb: r.rgb),
            title: Text('${r.label}: ${r.ssidText}'),
            subtitle: Text(r.summaryText),
          ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Extended networks',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (floor.chains.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'No network name is shared by two routers on this floor, so '
              'there is no chain to trace.',
              key: ValueKey('no-chains'),
            ),
          ),
        for (final (i, chain) in floor.chains.indexed)
          ListTile(
            key: ValueKey('chain-$i'),
            minTileHeight: kTarget,
            leading: const Icon(Icons.hub_outlined),
            title: Text(
              '${chain.name}: '
              '${chain.routerIds.map((id) => floor.routerById(id)?.label ?? id).join(', ')}',
            ),
            subtitle: Text(_chainText(floor, chain)),
            onTap: () => _showChain(chain),
          ),
        if (floor.chains.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                _legendRow(const ZoneSwatch(dead: false), weakZoneText(t)),
                _legendRow(const ZoneSwatch(dead: true), deadZoneText(t)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _legendRow(Widget swatch, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      swatch,
      const SizedBox(width: 6),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );

  String _chainText(RouterFloor floor, RouterChain chain) {
    String label(String id) => floor.routerById(id)?.label ?? id;
    final lines = [
      for (final link in chain.links)
        linkText(link, label(link.from), label(link.to)),
    ];
    if (chain.links.isEmpty) {
      lines.add('Fewer than two of these routers are placed on this floor.');
    } else if (chain.weakCells + chain.deadCells == 0) {
      lines.add('No weak or dead gap between them.');
    } else {
      lines.add(
        '${chain.gapAreaM2.round()} m² weak or dead between them '
        '(${chain.deadCells} dead, ${chain.weakCells} weak cells)',
      );
    }
    return lines.join('\n');
  }

  void _showRouter(MapRouter r) {
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
              Text(r.label, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                r.lowConfidence
                    ? 'Low confidence placement'
                    : 'Placed with confidence',
                key: const ValueKey('router-confidence'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              for (final n in r.networks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${n.name} · ${n.bssid} · ${n.maxRssiDbm} dBm',
                    style: mono(size: 13),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '${r.areaM2.round()} m² at or above '
                '${_data!.thresholds.deadDbm} dBm, '
                '${r.goodAreaM2.round()} m² good',
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Link colours: the gap's signal level, since that is what a link reports.
Color linkColor(String status) => switch (status) {
  'dead' => AppColors.dead,
  'weak' => AppColors.fair,
  'covered' => Colors.white,
  _ => AppColors.textMuted,
};

/// A placed router: a disc in its identity colour with its number. Low
/// confidence: a hollow ring at 40% opacity with a "?" badge, as the access
/// point markers, so it does not rely on colour alone.
class RouterMarker extends StatelessWidget {
  const RouterMarker({
    super.key,
    required this.number,
    required this.rgb,
    required this.lowConfidence,
    this.size = 32,
  });

  final int number;
  final int rgb;
  final bool lowConfidence;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Color(0xFF000000 | rgb);
    final text = Text(
      '$number',
      style: TextStyle(
        color: lowConfidence ? color : Colors.white,
        fontWeight: FontWeight.w800,
        fontSize: size * 0.45,
      ),
    );
    if (!lowConfidence) {
      return Center(
        child: Container(
          key: const ValueKey('router-solid'),
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: size / 16),
          ),
          child: text,
        ),
      );
    }
    final badge = size * 0.5;
    return Center(
      child: SizedBox(
        key: const ValueKey('router-hollow'),
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
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.surface,
                    border: Border.all(color: color, width: size / 10),
                  ),
                  child: text,
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
                  border: Border.all(color: color, width: 1),
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

/// The router's colour and number, for the list.
class RouterSwatch extends StatelessWidget {
  const RouterSwatch({super.key, required this.number, required this.rgb});

  final int number;
  final int rgb;

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: Color(0xFF000000 | rgb),
      shape: BoxShape.circle,
    ),
    child: Text(
      '$number',
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
    ),
  );
}
