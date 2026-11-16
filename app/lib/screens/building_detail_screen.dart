import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../theme.dart';
import '../widgets/plan_thumb.dart';
import 'building_form_screen.dart';
import 'floor_form_screen.dart';
import 'survey_screen.dart';

/// One building: details, its floors with their plans, and where a survey
/// starts. Viewers can look but not change anything.
class BuildingDetailScreen extends StatefulWidget {
  const BuildingDetailScreen({
    super.key,
    required this.session,
    required this.building,
    this.pickPlan = pickPlanFromGallery,
    this.openDb = LocalDb.open,
  });

  final Session session;
  final Building building;
  final PlanPicker pickPlan;
  final Future<LocalDb> Function() openDb;

  @override
  State<BuildingDetailScreen> createState() => _BuildingDetailScreenState();
}

class _BuildingDetailScreenState extends State<BuildingDetailScreen> {
  late Building _building = widget.building;
  Floor? _startFloor;
  bool _loading = true;
  String? _error;
  int _version = 0;
  bool _deleting = false;

  ApiClient get _api => widget.session.api;
  bool get _canEdit => canEditBuildings(widget.session.user!);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final b = await _api.building(_building.id);
      if (!mounted) return;
      setState(() {
        _building = b;
        _version++;
        _startFloor = b.floors.where((f) => f.id == _startFloor?.id).isNotEmpty
            ? b.floors.firstWhere((f) => f.id == _startFloor!.id)
            : (b.floors.isEmpty ? null : b.floors.first);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editBuilding() async {
    final saved = await Navigator.of(context).push<Building>(
      MaterialPageRoute(
        builder: (_) =>
            BuildingFormScreen(session: widget.session, building: _building),
      ),
    );
    if (saved != null) await _load();
  }

  Future<void> _editFloor([Floor? floor]) async {
    final saved = await Navigator.of(context).push<Floor>(
      MaterialPageRoute(
        builder: (_) => FloorFormScreen(
          session: widget.session,
          buildingId: _building.id,
          floor: floor,
          existingLevels: [for (final f in _building.floors) f.level],
          pickPlan: widget.pickPlan,
        ),
      ),
    );
    if (saved != null) await _load();
  }

  Future<bool> _confirmDelete({
    required String title,
    required String body,
    required String action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              minimumSize: const Size(0, 44),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _deleteFailure(ApiException e) => e.isNetwork
      ? "You're offline. Nothing was deleted."
      : 'Could not delete: ${e.message}';

  Future<void> _deleteBuilding() async {
    final b = _building;
    final n = b.floors.length;
    final ok = await _confirmDelete(
      title: 'Delete ${b.name}?',
      body:
          'This deletes the building, its $n floor${n == 1 ? '' : 's'} with '
          'their floor plans, and every survey done here: readings, heatmaps '
          'and access points. This cannot be undone.',
      action: 'Delete building',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await _api.deleteBuilding(b.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _toast(_deleteFailure(e));
      return;
    }
    await _forgetLocalSurvey(buildingId: b.id);
    if (!mounted) return;
    _toast('${b.name} was deleted.');
    Navigator.of(context).pop();
  }

  /// A survey of the deleted building or floor that this phone never
  /// finished can no longer be uploaded, so its saved readings and the
  /// "resume" note go too.
  Future<void> _forgetLocalSurvey({String? buildingId, String? floorId}) async {
    try {
      final db = await widget.openDb();
      final a = await db.activeFor(widget.session.user!.id);
      if (a == null) return;
      final sameBuilding = buildingId != null && a.buildingId == buildingId;
      final sameFloor = floorId != null && a.floorId == floorId;
      if (sameBuilding || sameFloor) {
        await db.discardSurvey(a.surveyId);
      }
    } catch (_) {
      // No local database: nothing to forget.
    }
  }

  Future<void> _deleteFloor(Floor f) async {
    final ok = await _confirmDelete(
      title: 'Delete ${f.label}?',
      body:
          'This deletes the floor, its floor plan and the readings, heatmaps '
          'and access points recorded on it. Surveys of the other floors are '
          'kept. This cannot be undone.',
      action: 'Delete floor',
    );
    if (!ok || !mounted) return;
    setState(() => _deleting = true);
    try {
      await _api.deleteFloor(f.id);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _toast(_deleteFailure(e));
      return;
    }
    await _forgetLocalSurvey(floorId: f.id);
    if (!mounted) return;
    setState(() => _deleting = false);
    _toast('${f.label} was deleted.');
    await _load();
  }

  Future<void> _startSurvey() async {
    final floor = _startFloor;
    if (floor == null) return;
    await SurveyScreen.open(
      context,
      session: widget.session,
      building: _building,
      floors: _building.floors,
      floor: floor,
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final b = _building;
    return Scaffold(
      appBar: AppBar(
        title: Text(b.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_canEdit)
            IconButton(
              tooltip: 'Edit building',
              icon: const Icon(Icons.edit_outlined),
              onPressed: _editBuilding,
            ),
          if (_canEdit)
            IconButton(
              key: const ValueKey('delete-building'),
              tooltip: 'Delete building',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleting ? null : _deleteBuilding,
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              if (b.address != null || b.description != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: glowCard(strength: 0.06),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (b.address != null)
                        Text(
                          b.address!,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (b.address != null && b.description != null)
                        const SizedBox(height: 6),
                      if (b.description != null)
                        Text(
                          b.description!,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 15,
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'FLOORS (${b.floors.length})',
                      style: mono(
                        size: 13,
                        weight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  if (_canEdit)
                    TextButton.icon(
                      onPressed: _loading ? null : () => _editFloor(),
                      icon: const Icon(Icons.add),
                      label: const Text('Add floor'),
                    ),
                ],
              ),
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
                TextButton(onPressed: _load, child: const Text('Try again')),
              ],
              if (_loading && b.floors.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loading && b.floors.isEmpty && _error == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _canEdit
                        ? 'No floors yet. Add the first one to start a survey.'
                        : 'This building has no floors yet.',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                ),
              for (final f in b.floors)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.all(10),
                    leading: PlanThumb(
                      api: _api,
                      floor: f,
                      cacheBust: _version,
                    ),
                    title: Text(
                      f.label,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      'Level ${f.level} · ${f.heightM.toStringAsFixed(1)} m high'
                      '${f.hasPlan ? ' · plan uploaded' : ' · no plan'}',
                    ),
                    trailing: _canEdit
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Edit ${f.label}',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () => _editFloor(f),
                              ),
                              IconButton(
                                key: ValueKey('delete-floor-${f.id}'),
                                tooltip: 'Delete ${f.label}',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _deleting
                                    ? null
                                    : () => _deleteFloor(f),
                              ),
                            ],
                          )
                        : null,
                    onTap: _canEdit ? () => _editFloor(f) : null,
                  ),
                ),
              if (_canEdit && b.floors.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: glowCard(strength: 0.08),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Start a survey',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        key: ValueKey('start-${b.floors.length}-$_version'),
                        initialValue: _startFloor?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Floor to start on',
                        ),
                        items: [
                          for (final f in b.floors)
                            DropdownMenuItem(
                              value: f.id,
                              child: Text('${f.label} (level ${f.level})'),
                            ),
                        ],
                        onChanged: (id) => setState(
                          () => _startFloor = b.floors.firstWhere(
                            (f) => f.id == id,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _startFloor == null ? null : _startSurvey,
                        icon: const Icon(Icons.radar),
                        label: const Text('Continue to survey'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
