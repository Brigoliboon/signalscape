import 'dart:async';

import 'package:flutter/material.dart';

import '../config.dart';
import '../core/sync_engine.dart';
import '../data/active_survey.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../data/user_models.dart';
import '../survey/finish.dart';
import '../survey/gone_survey.dart';
import '../theme.dart';
import 'building_detail_screen.dart';
import 'building_form_screen.dart';
import 'floor_form_screen.dart';
import 'survey_history_screen.dart';
import 'survey_screen.dart';
import 'users_screen.dart';
import 'viewer_screen.dart';
import 'profile_screen.dart';

/// How the building list can be ordered. [value] is the API's `sort`.
enum BuildingSort {
  nameAsc('name', 'Name A–Z'),
  nameDesc('-name', 'Name Z–A'),
  newest('-created_at', 'Newest first'),
  oldest('created_at', 'Oldest first');

  const BuildingSort(this.value, this.label);

  final String value;
  final String label;
}

/// Home screen: the buildings you can see, with search, sort and paging.
/// Also offers to resume a survey the app lost when it was closed.
class BuildingsScreen extends StatefulWidget {
  const BuildingsScreen({
    super.key,
    required this.session,
    this.pageSize = 20,
    this.openDb = LocalDb.open,
    this.checkUnfinished = true,
  });

  final Session session;
  final int pageSize;
  final Future<LocalDb> Function() openDb;

  /// Whether to look for an unfinished survey. Off in tests that do not care.
  final bool checkUnfinished;

  @override
  State<BuildingsScreen> createState() => _BuildingsScreenState();
}

class _BuildingsScreenState extends State<BuildingsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  BuildingSort _sort = BuildingSort.nameAsc;
  final List<Building> _items = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  String? _error;
  ActiveSurvey? _unfinished;
  bool _unfinishedGone = false;
  int _generation = 0;

  ApiClient get _api => widget.session.api;
  bool get _canEdit => canEditBuildings(widget.session.user!);

  @override
  void initState() {
    super.initState();
    _reload();
    if (widget.checkUnfinished) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _findUnfinished(true),
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Starts again from page 1. A newer call makes an older answer be ignored.
  Future<void> _reload() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.buildingPage(
        q: _search.text,
        page: 1,
        pageSize: widget.pageSize,
        sort: _sort.value,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _total = page.total;
        _page = page.page;
      });
    } on ApiException catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e.message);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    final gen = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _api.buildingPage(
        q: _search.text,
        page: _page + 1,
        pageSize: widget.pageSize,
        sort: _sort.value,
      );
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(page.items);
        _total = page.total;
        _page = page.page;
      });
    } on ApiException catch (e) {
      if (mounted && gen == _generation) setState(() => _error = e.message);
    } finally {
      if (mounted && gen == _generation) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reload);
  }

  Future<void> _addBuilding() async {
    final created = await Navigator.of(context).push<Building>(
      MaterialPageRoute(
        builder: (_) => BuildingFormScreen(session: widget.session),
      ),
    );
    if (created == null || !mounted) return;
    await _open(created);
  }

  Future<void> _open(Building b) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => BuildingDetailScreen(
          session: widget.session,
          building: b,
          pickPlan: pickPlanFromGallery,
          openDb: widget.openDb,
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
    await _findUnfinished(false);
  }

  // --- the survey that was left unfinished ---

  Future<void> _findUnfinished(bool ask) async {
    try {
      final db = await widget.openDb();
      final a = await db.activeFor(widget.session.user!.id);
      if (!mounted) return;
      final gone = a != null && await localSurveyTargetGone(_api, a);
      if (!mounted) return;
      setState(() {
        _unfinished = a;
        _unfinishedGone = gone;
      });
      if (a != null && ask) {
        if (gone) {
          await _askToDiscard(a);
        } else {
          await _askAboutUnfinished(a);
        }
      }
    } catch (_) {
      // No local database (or it cannot be read): nothing to resume.
    }
  }

  Future<void> _askAboutUnfinished(ActiveSurvey a) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Unfinished survey'),
        content: Text(
          'The app was closed in the middle of a survey at '
          '${a.buildingName}: ${a.readings} readings, ${a.checkpoints} '
          'checkpoints. Resume it, or end it now and process what was '
          'collected?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Later'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'end'),
            child: const Text('End survey'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, 'resume'),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'resume') await _resume(a);
    if (choice == 'end') await _endUnfinished(a);
  }

  Future<void> _resume(ActiveSurvey a) async {
    try {
      final b = await _api.building(a.buildingId);
      if (!mounted) return;
      final floor = b.floors.where((f) => f.id == a.floorId);
      if (floor.isEmpty) {
        await _askToDiscard(a);
        return;
      }
      await SurveyScreen.open(
        context,
        session: widget.session,
        building: b,
        floors: b.floors,
        floor: floor.first,
        resume: a,
      );
      if (mounted) await _findUnfinished(false);
    } on ApiException catch (e) {
      if (isGoneStatus(e.statusCode)) {
        await _askToDiscard(a);
      } else {
        _toast('Could not load the building: ${e.message}');
      }
    }
  }

  Future<void> _endUnfinished(ActiveSurvey a) async {
    _toast('Uploading and processing the survey…');
    try {
      final db = await widget.openDb();
      await finishSurvey(
        api: _api,
        db: db,
        engine: SyncEngine(
          store: db,
          transport: ApiSyncTransport(_api),
          batchSize: syncBatchSize,
        ),
        surveyId: a.surveyId,
      );
      if (!mounted) return;
      setState(() => _unfinished = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Survey finished and processed.'),
            action: SnackBarAction(
              label: 'View 3D',
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => ViewerScreen(
                    api: _api,
                    surveyId: a.surveyId,
                    canProcess: widget.session.user?.role != 'viewer',
                  ),
                ),
              ),
            ),
          ),
        );
    } on SyncException catch (e) {
      if (e.isGone) {
        await _askToDiscard(a);
      } else {
        _toast('Upload not finished: ${e.message} It is still saved here.');
      }
    } on ApiException catch (e) {
      if (isGoneStatus(e.statusCode)) {
        await _askToDiscard(a);
      } else {
        _toast(e.message);
      }
    }
  }

  Future<void> _askToDiscard(ActiveSurvey a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text(localSurveyGoneTitle),
        content: const Text(localSurveyGoneMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            key: const ValueKey('discard-local-survey'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _discard(a);
  }

  Future<void> _discard(ActiveSurvey a) async {
    try {
      final db = await widget.openDb();
      await db.discardSurvey(a.surveyId);
    } catch (_) {
      // Nothing else we can do; the card is still hidden below.
    }
    if (!mounted) return;
    setState(() {
      _unfinished = null;
      _unfinishedGone = false;
    });
    _toast(localSurveyDiscardedMessage);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.session.user!;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Buildings'),
        actions: [
          IconButton(
            key: const ValueKey('open-history'),
            tooltip: 'Survey history',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => SurveyHistoryScreen(
                  session: widget.session,
                  openDb: widget.openDb,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: widget.session.signOut,
            child: const Text('Sign out'),
          ),
          IconButton(
            key: const ValueKey('open-profile'),
            tooltip: 'Profile and settings',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ProfileScreen(
                  session: widget.session,
                  openDb: widget.openDb,
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              onPressed: _addBuilding,
              icon: const Icon(Icons.add),
              label: const Text('Add building'),
            )
          : null,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            children: [
              Text(
                'SIGNED IN AS ${user.email.toUpperCase()} · ${user.role.toUpperCase()}',
                style: mono(
                  size: 12,
                  weight: FontWeight.w600,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 12),
              if (canManageUsers(user.role)) ...[
                Card(
                  child: ListTile(
                    key: const ValueKey('open-users'),
                    leading: const Icon(Icons.group_outlined),
                    title: const Text('Manage users'),
                    subtitle: const Text('Roles, access and accounts'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => UsersScreen(session: widget.session),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_unfinished != null) ...[
                _UnfinishedCard(
                  survey: _unfinished!,
                  gone: _unfinishedGone,
                  onResume: () => _resume(_unfinished!),
                  onEnd: () => _endUnfinished(_unfinished!),
                  onDiscard: () => _askToDiscard(_unfinished!),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _reload(),
                decoration: InputDecoration(
                  hintText: 'Search buildings',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            _reload();
                          },
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading && _items.isEmpty
                          ? 'Loading…'
                          : '$_total building${_total == 1 ? '' : 's'}',
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<BuildingSort>(
                      value: _sort,
                      dropdownColor: AppColors.surfaceHigh,
                      items: [
                        for (final s in BuildingSort.values)
                          DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: (s) {
                        if (s == null) return;
                        setState(() => _sort = s);
                        _reload();
                      },
                    ),
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
                TextButton(onPressed: _reload, child: const Text('Try again')),
              ],
              if (_loading && _items.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loading && _items.isEmpty && _error == null)
                _EmptyState(
                  canEdit: _canEdit,
                  searching: _search.text.isNotEmpty,
                ),
              for (final b in _items)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(
                      b.name,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: b.address == null ? null : Text(b.address!),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(b),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.canEdit, required this.searching});

  final bool canEdit;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final text = searching
        ? 'No building matches your search.'
        : canEdit
        ? 'No buildings yet. Add the first one to start surveying.'
        : 'No buildings here. Viewers see surveys that are shared with them, '
              'not the building list.';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 15),
      ),
    );
  }
}

class _UnfinishedCard extends StatelessWidget {
  const _UnfinishedCard({
    required this.survey,
    required this.gone,
    required this.onResume,
    required this.onEnd,
    required this.onDiscard,
  });

  final ActiveSurvey survey;
  final bool gone;
  final VoidCallback onResume;
  final VoidCallback onEnd;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: glowCard(strength: 0.12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Unfinished survey',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            gone
                ? localSurveyGoneMessage
                : '${survey.buildingName} · ${survey.readings} readings',
            style: const TextStyle(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          if (gone)
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('discard-unfinished'),
                onPressed: onDiscard,
                child: const Text('Discard'),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: onResume,
                    child: const Text('Resume'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onEnd,
                    child: const Text('End survey'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
