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
/// strongest-signal heatmap. Opens on extended networks (a named SSID served
/// by two or more routers). One floor at a time: the network's heatmap, the
/// likely main router and its extenders linked as a chain, and the weak and
/// dead gaps along those links. Per-router footprints are not the default
/// view; reach comes from the heatmap.
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

  /// The extended network on show, by SSID.
  String? _ssid;
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

  ExtendedNetwork? get _network =>
      _ssid == null ? null : _data?.networkNamed(_ssid!);

  ExtendedNetworkFloor? get _networkFloor {
    final level = _level;
    return level == null ? null : _network?.floorAt(level);
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
      final network = data.extendedNetworks.firstOrNull;
      final firstFloor = network?.floors.firstOrNull;
      setState(() {
        _data = data;
        _pictures.clear();
        _ssid = network?.ssid;
        _level = firstFloor?.level;
        _stage = data.isEmpty
            ? _Stage.empty
            : (data.extendedNetworks.isEmpty ? _Stage.empty : _Stage.ready);
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

  void _pickFloor(int level) {
    setState(() => _level = level);
    final fit = _fitFor(_networkFloor);
    if (fit != null) _map.fitCamera(fit);
  }

  void _pickNetwork(String? ssid) {
    if (ssid == null || ssid == _ssid) return;
    final network = _data?.networkNamed(ssid);
    final floor = network?.floors.firstOrNull;
    setState(() {
      _ssid = ssid;
      if (floor != null && network?.floorAt(_level ?? floor.level) == null) {
        _level = floor.level;
      }
    });
    final fit = _fitFor(_networkFloor);
    if (fit != null) _map.fitCamera(fit);
  }

  CameraFit? _fitFor(ExtendedNetworkFloor? floor) {
    if (floor == null) return null;
    final points = <LatLng>[];
    final cover = floor.coverage;
    if (cover != null) {
      points.addAll([cover.pictureSouthWest, cover.pictureNorthEast]);
    }
    for (final r in floor.routers) {
      if (r.at != null) points.add(r.at!);
    }
    if (points.isEmpty) return null;
    return CameraFit.coordinates(
      coordinates: points,
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 24),
      maxZoom: 21,
    );
  }

  HeatImage? _coverageImage(ExtendedNetworkFloor floor) {
    final heat = floor.coverage;
    if (heat == null) return null;
    return _pictures.putIfAbsent(
      'c|$_level|$_ssid',
      () => renderHeatPng(HeatRequest(grid: heat.grid)),
    );
  }

  HeatImage? _gapImage(ExtendedNetworkFloor floor) {
    final heat = floor.gaps;
    if (heat == null) return null;
    return _pictures.putIfAbsent(
      'g|$_level|$_ssid',
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
        _data != null && !_data!.isEmpty
            ? 'No extended networks'
            : 'No routers',
        _data != null && !_data!.isEmpty
            ? 'A network is extended when two or more routers broadcast the '
                  'same name. This survey has none to trace.'
            : 'No network survived cleaning on any floor, so there is no '
                  'router to show.',
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
    final network = _network!;
    final floor = _networkFloor;
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Stack(
            children: [
              if (floor != null) _mapView(floor) else _noFloor(network),
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: _floorPanel(data, network, floor),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(flex: 2, child: _list(data, network, floor)),
      ],
    );
  }

  Widget _noFloor(ExtendedNetwork network) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No routers of ${network.name} on this floor.',
          key: const ValueKey('no-network-floor'),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _mapView(ExtendedNetworkFloor floor) {
    final cover = floor.coverage;
    final coverImage = _coverageImage(floor);
    final gaps = floor.gaps;
    final gapImage = _showGaps ? _gapImage(floor) : null;
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
        if (cover != null && coverImage != null)
          OverlayImageLayer(
            key: const ValueKey('network-heat'),
            overlayImages: [
              OverlayImage(
                bounds: LatLngBounds(
                  cover.pictureSouthWest,
                  cover.pictureNorthEast,
                ),
                imageProvider: MemoryImage(coverImage.png),
                gaplessPlayback: true,
                filterQuality: FilterQuality.none,
              ),
            ],
          ),
        if (gaps != null && gapImage != null)
          OverlayImageLayer(
            key: const ValueKey('gaps-0'),
            overlayImages: [
              OverlayImage(
                bounds: LatLngBounds(
                  gaps.pictureSouthWest,
                  gaps.pictureNorthEast,
                ),
                imageProvider: MemoryImage(gapImage.png),
                gaplessPlayback: true,
                filterQuality: FilterQuality.none,
              ),
            ],
          ),
        PolylineLayer(
          key: const ValueKey('chain-links'),
          simplificationTolerance: 0,
          polylines: [
            for (final link in floor.links)
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
              if (r.positionDetermined && r.at != null)
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

  Widget _floorPanel(
    RouterCoverage data,
    ExtendedNetwork network,
    ExtendedNetworkFloor? floor,
  ) {
    final floors = network.floors;
    return Container(
      key: const ValueKey('router-floors'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: _panel(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.extendedNetworks.length > 1)
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const ValueKey('network-picker'),
                value: network.ssid,
                isExpanded: true,
                items: [
                  for (final n in data.extendedNetworks)
                    DropdownMenuItem(value: n.ssid, child: Text(n.name)),
                ],
                onChanged: _pickNetwork,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              child: Text(
                network.name,
                key: const ValueKey('network-name'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (floors.length > 1)
                  for (final f in floors)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('router-floor-${f.level}'),
                        label: Text(f.label),
                        selected: floor != null && f.level == floor.level,
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
        ],
      ),
    );
  }

  Widget _list(
    RouterCoverage data,
    ExtendedNetwork network,
    ExtendedNetworkFloor? floor,
  ) {
    final t = data.thresholds;
    final routers = floor?.routers ?? const <ExtendedRouter>[];
    final count = network.routerCount;
    return ListView(
      key: const ValueKey('router-list'),
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '${network.name} · '
            '${count == 1 ? '1 router' : '$count routers'} in this network · '
            '${data.routerCount} in the survey, from ${data.bssidCount} '
            'BSSIDs',
            key: const ValueKey('router-count'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Likely main is an estimate: Wi-Fi scans do not say which device '
            'is the main router or an extender. Reach is the heatmap.',
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ),
        if (floor == null)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text('No routers of this network on this floor.'),
          ),
        for (final r in routers)
          ListTile(
            key: ValueKey('router-tile-${r.number}'),
            minTileHeight: kTarget,
            leading: RouterSwatch(number: r.number, rgb: r.rgb),
            title: Text(r.label),
            subtitle: Text('${r.positionText} · strongest ${r.maxRssiDbm} dBm'),
            onTap: () => _showRouter(r),
          ),
        if (floor != null) ...[
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Links and gaps',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_gapText(floor), key: const ValueKey('link-summary')),
          ),
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

  String _gapText(ExtendedNetworkFloor floor) {
    String label(String id) => floor.routerById(id)?.label ?? id;
    final lines = [
      for (final link in floor.links)
        linkText(link, label(link.from), label(link.to)),
    ];
    if (floor.links.isEmpty) {
      lines.add('Fewer than two of these routers are placed on this floor.');
    } else if (floor.weakCells + floor.deadCells == 0) {
      lines.add('No weak or dead gap between them.');
    } else {
      lines.add(
        '${floor.gapAreaM2.round()} m² weak or dead between them '
        '(${floor.deadCells} dead, ${floor.weakCells} weak cells)',
      );
    }
    return lines.join('\n');
  }

  void _showRouter(ExtendedRouter r) {
    final detail = _floor?.routerById(r.id);
    final roleLine = !r.positionDetermined
        ? r.positionText
        : (r.role == RouterRole.likelyMain
              ? 'Likely main (estimate)'
              : 'Extender');
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
                roleLine,
                key: const ValueKey('router-role'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (r.role == RouterRole.likelyMain &&
                  (_data?.mainHeuristic ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _data!.mainHeuristic,
                  key: const ValueKey('main-heuristic'),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              if (r.positionDetermined) ...[
                const SizedBox(height: 8),
                Text(
                  r.lowConfidence
                      ? 'Low confidence placement'
                      : 'Placed with confidence',
                  key: const ValueKey('router-confidence'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Strongest reading of this network: ${r.maxRssiDbm} dBm',
                style: mono(size: 13),
              ),
              if (detail != null) ...[
                const SizedBox(height: 8),
                for (final n in detail.networks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${n.name} · ${n.bssid} · ${n.maxRssiDbm} dBm',
                      style: mono(size: 13),
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  '${detail.areaM2.round()} m² at or above '
                  '${_data!.thresholds.deadDbm} dBm, '
                  '${detail.goodAreaM2.round()} m² good',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
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
