import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/export_share.dart';
import '../data/api_client.dart';
import '../data/summary_models.dart';
import '../theme.dart';

enum _Stage { loading, ready, notProcessed, failed }

/// What a processed survey found (FR-19): readings, area covered and the
/// share of good, fair and dead cells, in total and per floor, with exports
/// of the readings (CSV) and of the coverage (GeoJSON) (FR-21).
class SurveySummaryScreen extends StatefulWidget {
  const SurveySummaryScreen({
    super.key,
    required this.api,
    required this.surveyId,
    this.canProcess = false,
    this.shareFile = shareFileWithPlugin,
  });

  final ApiClient api;
  final String surveyId;

  /// Surveyors and Admins can start processing a survey that has none yet.
  final bool canProcess;

  /// Defaults to the phone's share sheet; tests pass their own.
  final FileSharer shareFile;

  @override
  State<SurveySummaryScreen> createState() => _SurveySummaryScreenState();
}

class _SurveySummaryScreenState extends State<SurveySummaryScreen> {
  _Stage _stage = _Stage.loading;
  SurveySummaryData? _data;
  String? _message;
  bool _offline = false;
  bool _busy = false;
  String? _exporting;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _message = null;
      _offline = false;
    });
    try {
      final json = await widget.api.surveySummary(widget.surveyId);
      if (!mounted) return;
      setState(() {
        _data = SurveySummaryData.fromJson(json);
        _stage = _Stage.ready;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = e.statusCode == 409 ? _Stage.notProcessed : _Stage.failed;
        _offline = e.isNetwork;
        _message = e.message;
      });
    }
  }

  Future<void> _process() async {
    setState(() => _busy = true);
    try {
      await widget.api.process(widget.surveyId);
      if (!mounted) return;
      setState(() => _busy = false);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('Could not process the survey: ${e.message}');
    }
  }

  Future<void> _export(String kind) async {
    setState(() => _exporting = kind);
    try {
      final List<int> bytes;
      final String name;
      final String mime;
      if (kind == 'csv') {
        bytes = await widget.api.exportCsv(widget.surveyId);
        name = exportFileName(widget.surveyId, 'csv');
        mime = 'text/csv';
      } else {
        final json = await widget.api.surveyGeoJson(widget.surveyId);
        bytes = utf8.encode(jsonEncode(json));
        name = exportFileName(widget.surveyId, 'geojson');
        mime = 'application/geo+json';
      }
      await widget.shareFile(name: name, mimeType: mime, bytes: bytes);
    } on ApiException catch (e) {
      _toast(
        e.isNetwork
            ? "You're offline. ${e.message}"
            : 'Could not export: ${e.message}',
      );
    } catch (_) {
      _toast('Could not open the share sheet on this phone.');
    } finally {
      if (mounted) setState(() => _exporting = null);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Survey summary')),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.ready => _content(_data!),
          _Stage.notProcessed => _notice(
            title: 'Not processed yet',
            text: widget.canProcess
                ? 'This survey has no results yet. Process it to see the '
                      'summary.'
                : 'This survey has no results yet. Ask the surveyor to '
                      'process it.',
            action: widget.canProcess
                ? FilledButton(
                    key: const ValueKey('process-now'),
                    onPressed: _busy ? null : _process,
                    child: Text(_busy ? 'Processing…' : 'Process now'),
                  )
                : null,
          ),
          _Stage.failed => _notice(
            title: _offline ? "You're offline" : "Couldn't load the summary",
            text: _message ?? 'Something went wrong.',
            action: OutlinedButton(
              onPressed: _load,
              child: const Text('Try again'),
            ),
          ),
        },
      ),
    );
  }

  Widget _notice({
    required String title,
    required String text,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }

  Widget _content(SurveySummaryData d) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          key: const ValueKey('summary-total'),
          padding: const EdgeInsets.all(16),
          decoration: glowCard(strength: 0.12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('All floors', style: Theme.of(context).textTheme.titleLarge),
              if (d.processedAt != null)
                Text(
                  'Processed ${_when(d.processedAt!)}',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              const SizedBox(height: 12),
              _stats([
                ('Floors', '${d.floors.length}'),
                ('Readings', '${d.cleanedReadings} of ${d.rawReadings}'),
                ('Area covered', _area(d.areaM2)),
                ('Access points', '${d.accessPoints}'),
              ]),
              const SizedBox(height: 12),
              _levelBar(d.goodPct, d.fairPct, d.deadPct, d.areaM2 > 0),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final f in d.floors)
          Card(
            key: ValueKey('floor-${f.level}'),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    f.label,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _stats([
                    ('Readings', '${f.cleanedReadings} of ${f.rawReadings}'),
                    ('Area covered', _area(f.areaM2)),
                    ('Access points', '${f.accessPoints}'),
                  ]),
                  const SizedBox(height: 10),
                  _levelBar(f.goodPct, f.fairPct, f.deadPct, f.hasCoverage),
                ],
              ),
            ),
          ),
        const SizedBox(height: 4),
        Text('Export', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const ValueKey('export-csv'),
          onPressed: _exporting == null ? () => _export('csv') : null,
          icon: const Icon(Icons.table_chart_outlined),
          label: Text(
            _exporting == 'csv' ? 'Preparing…' : 'Export readings (CSV)',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const ValueKey('export-geojson'),
          onPressed: _exporting == null ? () => _export('geojson') : null,
          icon: const Icon(Icons.public),
          label: Text(
            _exporting == 'geojson'
                ? 'Preparing…'
                : 'Export coverage (GeoJSON)',
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'The CSV has every cleaned reading (time, position, network, '
          'signal). The GeoJSON has the coverage cells and access points. '
          'Both open the phone\'s share sheet.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 13),
        ),
      ],
    );
  }

  Widget _stats(List<(String, String)> rows) => Column(
    children: [
      for (final (k, v) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  k,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ),
              Text(v, style: mono(size: 14)),
            ],
          ),
        ),
    ],
  );

  /// A bar split into good, fair and dead, with each share in words.
  Widget _levelBar(double good, double fair, double dead, bool hasCoverage) {
    if (!hasCoverage) {
      return const Text(
        'No coverage to describe: no cleaned readings on this floor.',
        style: TextStyle(color: AppColors.textMuted),
      );
    }
    int flex(double v) => (v * 10).round().clamp(0, 1000);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 10,
            child: Row(
              children: [
                if (flex(good) > 0)
                  Expanded(
                    flex: flex(good),
                    child: const ColoredBox(color: AppColors.good),
                  ),
                if (flex(fair) > 0)
                  Expanded(
                    flex: flex(fair),
                    child: const ColoredBox(color: AppColors.fair),
                  ),
                if (flex(dead) > 0)
                  Expanded(
                    flex: flex(dead),
                    child: const ColoredBox(color: AppColors.dead),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 14,
          children: [
            Text('Good ${good.toStringAsFixed(1)}%'),
            Text('Fair ${fair.toStringAsFixed(1)}%'),
            Text('Dead ${dead.toStringAsFixed(1)}%'),
          ],
        ),
      ],
    );
  }

  static String _area(double m2) => m2 >= 10000
      ? '${(m2 / 10000).toStringAsFixed(2)} ha'
      : '${m2.round()} m²';

  static String _when(DateTime d) {
    final t = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
