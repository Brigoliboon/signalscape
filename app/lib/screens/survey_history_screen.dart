import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/session.dart';
import '../data/summary_models.dart';
import '../data/survey_models.dart';
import '../theme.dart';
import 'map_screen.dart';
import 'viewer_screen.dart';

/// Which surveys the history shows. [value] is the API's `status` filter.
enum SurveyFilter {
  all(null, 'All'),
  processed('processed', 'Processed'),
  completed('completed', 'Not processed'),
  active('active', 'In progress');

  const SurveyFilter(this.value, this.label);

  final String? value;
  final String label;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "16 Nov 2026, 14:05" in the phone's own time zone.
String formatSurveyDate(DateTime when) {
  final t = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year}, ${two(t.hour)}:${two(t.minute)}';
}

/// "12 min", "1 h 05 min", or null when the survey has not ended.
String? surveyDuration(SurveyInfo s) {
  final end = s.endedAt;
  if (end == null) return null;
  final minutes = end.difference(s.startedAt).inMinutes;
  if (minutes < 1) return 'under a minute';
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
}

String formatArea(double m2) =>
    m2 >= 10000 ? '${(m2 / 10000).toStringAsFixed(2)} ha' : '${m2.round()} m²';

/// Opens a survey's results on the 2D map, with a switch to the 3D view, or on
/// the 3D view when [in3d] is set.
Future<void> openSurveyResults(
  BuildContext context, {
  required ApiClient api,
  required String surveyId,
  required bool canProcess,
  bool in3d = false,
}) {
  Widget viewer() =>
      ViewerScreen(api: api, surveyId: surveyId, canProcess: canProcess);
  Widget map() => MapScreen(
    api: api,
    surveyId: surveyId,
    canProcess: canProcess,
    onOpen3d: (mapContext) => Navigator.of(
      mapContext,
    ).pushReplacement(MaterialPageRoute<void>(builder: (_) => viewer())),
  );
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => in3d ? viewer() : map()));
}

/// Past surveys, newest first, with a status filter and a building filter.
/// Tap one to see its details, open it on the map or in 3D, or delete it.
class SurveyHistoryScreen extends StatefulWidget {
  const SurveyHistoryScreen({
    super.key,
    required this.session,
    this.pageSize = 20,
    this.openDb = LocalDb.open,
    this.initialBuildingId,
    this.initialSurveyorId,
    this.initialSurveyorName,
  });

  final Session session;
  final int pageSize;
  final Future<LocalDb> Function() openDb;
  final String? initialBuildingId;
  final String? initialSurveyorId;
  final String? initialSurveyorName;

  @override
  State<SurveyHistoryScreen> createState() => _SurveyHistoryScreenState();
}

class _SurveyHistoryScreenState extends State<SurveyHistoryScreen> {
  final List<SurveyInfo> _items = [];
  final Map<String, String> _buildingNames = {};
  final Map<String, String> _surveyors = {};
  final List<_AreaRow> _areaRows = [];
  SurveyFilter _filter = SurveyFilter.all;
  late String? _buildingId = widget.initialBuildingId;
  late String? _surveyorId = widget.initialSurveyorId;
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  bool _overviewLoading = false;
  String? _overviewError;
  int _overviewCount = 0;
  int _overviewProcessed = 0;
  int _overviewGeneration = 0;

  ApiClient get _api => widget.session.api;
  bool get _isAdmin => widget.session.user!.role == 'admin';

  @override
  void initState() {
    super.initState();
    if (widget.initialSurveyorId != null) {
      _surveyors[widget.initialSurveyorId!] =
          widget.initialSurveyorName ?? 'Surveyor';
    }
    _init();
  }

  Future<void> _init() async {
    await _loadBuildings();
    if (!mounted) return;
    await _reload();
    if (!_isAdmin) return;
    _loadSurveyors();
    if (_surveyorId != null) _loadOverview();
  }

  /// Names for the cards and the building filter. The list still works
  /// without them (cards then say "Building").
  Future<void> _loadBuildings() async {
    try {
      final page = await _api.buildingPage(pageSize: 100);
      if (!mounted) return;
      setState(() {
        for (final b in page.items) {
          _buildingNames[b.id] = b.name;
        }
      });
    } on ApiException {
      // Not needed to show the surveys.
    }
  }

  Future<void> _reload() => _fetch(1);

  Future<void> _refresh() async {
    await _reload();
    if (!mounted) return;
    if (_surveyorId != null) await _loadOverview();
  }

  Future<void> _loadMore() => _fetch(_page + 1);

  Future<void> _loadSurveyors() async {
    if (!_isAdmin) return;
    try {
      final found = <String, String>{};
      var page = 1;
      while (true) {
        final result = await _api.userPage(
          page: page,
          pageSize: 100,
          sort: 'name',
        );
        for (final u in result.items) {
          if (u.role == 'admin' || u.role == 'surveyor') {
            found[u.id] = u.name;
          }
        }
        if (!result.hasMore) break;
        page++;
      }
      if (!mounted) return;
      setState(() => _surveyors.addAll(found));
    } on ApiException {
      // Not needed to show the surveys.
    }
  }

  Future<void> _loadOverview() async {
    if (!mounted) return;
    final surveyorId = _surveyorId;
    if (!_isAdmin || surveyorId == null) {
      if (mounted) {
        setState(() {
          _areaRows.clear();
          _overviewCount = 0;
          _overviewProcessed = 0;
          _overviewError = null;
          _overviewLoading = false;
        });
      }
      return;
    }
    final gen = ++_overviewGeneration;
    setState(() {
      _overviewLoading = true;
      _overviewError = null;
    });
    try {
      final surveys = <SurveyInfo>[];
      var page = 1;
      while (true) {
        final result = await _api.surveyPage(
          surveyorId: surveyorId,
          page: page,
          pageSize: 100,
        );
        surveys.addAll(result.items);
        if (surveys.length >= result.total || result.items.isEmpty) break;
        page++;
      }
      final rows = <_AreaRow>[];
      var processed = 0;
      for (final s in surveys.where((s) => s.isProcessed)) {
        processed++;
        try {
          final summary = SurveySummaryData.fromJson(
            await _api.surveySummary(s.id),
          );
          final building = _buildingName(s);
          for (final f in summary.floors) {
            rows.add(
              _AreaRow(building: building, floor: f.label, areaM2: f.areaM2),
            );
          }
        } on ApiException {
          // Not needed to show the surveys.
        }
      }
      if (!mounted || gen != _overviewGeneration) return;
      setState(() {
        _areaRows
          ..clear()
          ..addAll(rows);
        _overviewCount = surveys.length;
        _overviewProcessed = processed;
        _overviewLoading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _overviewGeneration) return;
      setState(() {
        _overviewLoading = false;
        _overviewError = e.isNetwork
            ? "You're offline. ${e.message}"
            : 'Could not load the area: ${e.message}';
      });
    }
  }

  /// A newer call makes an older answer be ignored.
  Future<void> _fetch(int page) async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _api.surveyPage(
        buildingId: _buildingId,
        status: _filter.value,
        surveyorId: _surveyorId,
        page: page,
        pageSize: widget.pageSize,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        if (page == 1) _items.clear();
        _items.addAll(result.items);
        _total = result.total;
        _page = result.page;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _loading = false;
        _error = e.isNetwork
            ? "You're offline. ${e.message}"
            : 'Could not load surveys: ${e.message}';
      });
    }
  }

  String _buildingName(SurveyInfo s) =>
      _buildingNames[s.buildingId] ?? 'Building';

  String _walkerName(SurveyInfo s) {
    if (s.surveyorId == widget.session.user!.id) return 'you';
    final name = s.surveyorName.isNotEmpty
        ? s.surveyorName
        : _surveyors[s.surveyorId];
    return name == null || name.isEmpty ? 'a surveyor' : name;
  }

  List<({String building, List<_AreaRow> rows})> _groupedAreas() {
    final groups = <String, List<_AreaRow>>{};
    for (final row in _areaRows) {
      groups.putIfAbsent(row.building, () => []).add(row);
    }
    return [
      for (final entry in groups.entries)
        (building: entry.key, rows: entry.value),
    ];
  }

  List<MapEntry<String, String>> get _surveyorOptions {
    final entries = _surveyors.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return entries;
  }

  bool _canDelete(SurveyInfo s) {
    final user = widget.session.user!;
    return canDeleteSurveys(user.role) &&
        (user.role == 'admin' || s.surveyorId == user.id);
  }

  Future<void> _openDetails(SurveyInfo s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      builder: (ctx) => _SurveyDetails(
        survey: s,
        buildingName: _buildingName(s),
        canDelete: _canDelete(s),
      ),
    );
    if (!mounted || action == null) return;
    final canProcess = widget.session.user!.role != 'viewer';
    switch (action) {
      case 'map':
      case '3d':
        await openSurveyResults(
          context,
          api: _api,
          surveyId: s.id,
          canProcess: canProcess,
          in3d: action == '3d',
        );
        // The survey may have been processed from the map screen.
        if (mounted) await _refresh();
      case 'delete':
        await _confirmDelete(s);
    }
  }

  Future<void> _confirmDelete(SurveyInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Delete this survey?'),
        content: Text(
          'The survey at ${_buildingName(s)} from '
          '${formatSurveyDate(s.startedAt)} will be deleted for good, with all '
          'its readings, checkpoints, heatmaps and estimated access points. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(0, 44),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete survey'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.deleteSurvey(s.id);
    } on ApiException catch (e) {
      _toast('Could not delete the survey: ${e.message}');
      return;
    }
    await _forgetLocal(s.id);
    if (!mounted) return;
    setState(() {
      _items.removeWhere((i) => i.id == s.id);
      _total = _total > 0 ? _total - 1 : 0;
    });
    _toast('Survey deleted.');
    if (_surveyorId != null) _loadOverview();
  }

  /// If the phone still holds this survey as "unfinished", forget it, so the
  /// next start does not offer to resume a survey that is gone.
  Future<void> _forgetLocal(String surveyId) async {
    try {
      final db = await widget.openDb();
      final a = await db.activeFor(widget.session.user!.id);
      if (a != null && a.surveyId == surveyId) await db.clearActive();
    } catch (_) {
      // No local database: nothing to forget.
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _overviewCard() {
    final title = Theme.of(context).textTheme.titleMedium;
    return Card(
      key: const ValueKey('surveyor-overview'),
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Surveyor overview', style: title),
            const SizedBox(height: 6),
            if (_overviewLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            else if (_overviewError != null) ...[
              Text(
                _overviewError!,
                style: const TextStyle(
                  color: AppColors.dead,
                  fontWeight: FontWeight.w600,
                ),
              ),
              TextButton(
                onPressed: _loadOverview,
                child: const Text('Try again'),
              ),
            ] else ...[
              Text(
                '$_overviewCount survey${_overviewCount == 1 ? '' : 's'} · '
                '$_overviewProcessed processed',
                style: const TextStyle(color: AppColors.textMuted),
              ),
              const SizedBox(height: 6),
              if (_areaRows.isEmpty)
                const Text(
                  'No processed area yet.',
                  style: TextStyle(color: AppColors.textMuted),
                )
              else
                for (final group in _groupedAreas()) ...[
                  Text(
                    group.building,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  for (final row in group.rows)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 2),
                      child: Text(
                        '${row.floor} — ${formatArea(row.areaM2)}',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ),
                  const SizedBox(height: 6),
                ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Survey history')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final f in SurveyFilter.values)
                    ChoiceChip(
                      key: ValueKey('filter-${f.name}'),
                      label: Text(f.label),
                      selected: f == _filter,
                      onSelected: (_) {
                        setState(() => _filter = f);
                        _reload();
                      },
                    ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading && _items.isEmpty
                          ? 'Loading…'
                          : '$_total survey${_total == 1 ? '' : 's'}',
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      key: const ValueKey('building-filter'),
                      value: _buildingNames.containsKey(_buildingId)
                          ? _buildingId
                          : null,
                      dropdownColor: AppColors.surfaceHigh,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All buildings'),
                        ),
                        for (final e in _buildingNames.entries)
                          DropdownMenuItem<String?>(
                            value: e.key,
                            child: Text(e.value),
                          ),
                      ],
                      onChanged: (id) {
                        setState(() => _buildingId = id);
                        _reload();
                      },
                    ),
                  ),
                ],
              ),
              if (_isAdmin)
                Align(
                  alignment: Alignment.centerRight,
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String?>(
                      key: const ValueKey('surveyor-filter'),
                      value: _surveyorId,
                      dropdownColor: AppColors.surfaceHigh,
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All surveyors'),
                        ),
                        for (final e in _surveyorOptions)
                          DropdownMenuItem<String?>(
                            value: e.key,
                            child: Text(e.value),
                          ),
                      ],
                      onChanged: (id) {
                        setState(() => _surveyorId = id);
                        _reload();
                        _loadOverview();
                      },
                    ),
                  ),
                ),
              if (_isAdmin && _surveyorId != null) _overviewCard(),
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.dead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(onPressed: _reload, child: const Text('Try again')),
              ],
              if (_loading && _items.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loading && _items.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    _filter == SurveyFilter.all &&
                            _buildingId == null &&
                            _surveyorId == null
                        ? 'No surveys yet. Finish a survey and it shows up here.'
                        : 'No surveys match this filter.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 15,
                    ),
                  ),
                ),
              for (final s in _items)
                Card(
                  key: ValueKey('survey-${s.id}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(
                      _buildingName(s),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      '${formatSurveyDate(s.startedAt)} · ${s.statusLabel}\n'
                      'Walked by ${_walkerName(s)}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openDetails(s),
                  ),
                ),
              if (_items.length < _total)
                OutlinedButton(
                  onPressed: _loading ? null : _loadMore,
                  child: Text(
                    _loading
                        ? 'Loading…'
                        : 'Load more (${_items.length} of $_total)',
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SurveyDetails extends StatelessWidget {
  const _SurveyDetails({
    required this.survey,
    required this.buildingName,
    required this.canDelete,
  });

  final SurveyInfo survey;
  final String buildingName;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final s = survey;
    final duration = surveyDuration(s);
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(k, style: const TextStyle(color: AppColors.textMuted)),
          ),
          Expanded(child: Text(v)),
        ],
      ),
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(buildingName, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              row('Status', s.statusLabel),
              row('Started', formatSurveyDate(s.startedAt)),
              if (duration != null) row('Length', duration),
              if (s.processedAt != null)
                row('Processed', formatSurveyDate(s.processedAt!)),
              if (s.deviceModel != null) row('Phone', s.deviceModel!),
              if (s.notes != null) row('Notes', s.notes!),
              if (!s.isProcessed) ...[
                const SizedBox(height: 8),
                Text(
                  s.status == 'completed'
                      ? 'This survey has not been processed yet, so there is no '
                            'heatmap. Open it on the map to process it.'
                      : 'This survey is still in progress.',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('open-map'),
                onPressed: () => Navigator.pop(context, 'map'),
                icon: const Icon(Icons.map_outlined),
                label: const Text('Open on the 2D map'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('open-3d'),
                onPressed: () => Navigator.pop(context, '3d'),
                icon: const Icon(Icons.view_in_ar_outlined),
                label: const Text('Open in 3D'),
              ),
              if (canDelete) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  key: const ValueKey('delete-survey'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.dead,
                    minimumSize: const Size(0, kTarget),
                  ),
                  onPressed: () => Navigator.pop(context, 'delete'),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete survey'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AreaRow {
  const _AreaRow({
    required this.building,
    required this.floor,
    required this.areaM2,
  });

  final String building;
  final String floor;
  final double areaM2;
}
