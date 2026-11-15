import 'package:flutter/material.dart';

import '../config.dart';
import '../core/levels.dart';
import '../core/sync_engine.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../survey/survey_controller.dart';
import '../theme.dart';
import '../widgets/radar.dart';
import '../widgets/trail_view.dart';
import 'viewer_screen.dart';

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({
    super.key,
    required this.session,
    required this.controller,
  });

  final Session session;
  final SurveyController controller;

  /// Opens the local queue, builds the controller and shows the screen.
  static Future<void> open(
    BuildContext context, {
    required Session session,
    required Building building,
    required List<Floor> floors,
    required Floor floor,
  }) async {
    final db = await LocalDb.open();
    final controller = SurveyController(
      api: session.api,
      db: db,
      engine: SyncEngine(
        store: db,
        transport: ApiSyncTransport(session.api),
        batchSize: syncBatchSize,
      ),
      thresholds: session.user!.thresholds,
      building: building,
      floors: floors,
      initialFloor: floor,
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SurveyScreen(session: session, controller: controller),
      ),
    );
    controller.dispose();
  }

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen> {
  SurveyController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.init();
  }

  Future<bool> _confirmLeave() async {
    if (c.phase == SurveyPhase.acquiring || c.phase == SurveyPhase.ready) {
      return true;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceHigh,
        title: const Text('Leave this survey?'),
        content: const Text(
          'Readings already taken stay on this phone and keep uploading, '
          'but the survey will not be finished or processed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep surveying'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  Future<void> _end() async {
    final ok = await c.end();
    if (ok && mounted) {
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) =>
              ViewerScreen(api: widget.session.api, surveyId: c.surveyId!),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final nav = Navigator.of(context);
            if (await _confirmLeave()) nav.pop();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text('Survey · ${c.floor.label}'),
              actions: [_OnlineChip(online: c.online)],
            ),
            body: SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _StatusCard(c: c),
                  const SizedBox(height: 12),
                  _Stats(c: c),
                  const SizedBox(height: 12),
                  _TrailCard(c: c),
                  const SizedBox(height: 10),
                  _Legend(t: c.thresholds),
                  const SizedBox(height: 10),
                  _SyncLine(c: c),
                  if (c.message != null) ...[
                    const SizedBox(height: 8),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        c.message!,
                        style: const TextStyle(
                          color: AppColors.accent,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                  if (c.error != null) ...[
                    const SizedBox(height: 8),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        c.error!,
                        style: const TextStyle(
                          color: AppColors.dead,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  _Actions(c: c, onEnd: _end),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OnlineChip extends StatelessWidget {
  const _OnlineChip({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppColors.good : AppColors.fair;
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 6),
            Text(
              online ? 'ONLINE' : 'OFFLINE',
              style: mono(size: 12, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.c});

  final SurveyController c;

  @override
  Widget build(BuildContext context) {
    final (title, color) = switch (c.phase) {
      SurveyPhase.acquiring => ('WAITING FOR GPS', AppColors.fair),
      SurveyPhase.ready => (
        c.gpsGoodEnough ? 'READY TO SCAN' : 'GPS TOO WEAK',
        c.gpsGoodEnough ? AppColors.good : AppColors.fair,
      ),
      SurveyPhase.active => ('SCANNING', AppColors.accent),
      SurveyPhase.paused => ('PAUSED', AppColors.fair),
      SurveyPhase.ending => ('UPLOADING', AppColors.accent),
      SurveyPhase.endFailed => ('NOT FINISHED', AppColors.dead),
      SurveyPhase.done => ('DONE', AppColors.good),
    };
    final wait = c.nextScanIn;
    final scanLine = c.phase == SurveyPhase.active
        ? 'Scans ${c.scansUsed}/4 per 2 min · '
              '${wait == Duration.zero ? 'ready' : 'next in ${wait.inSeconds + 1} s'}'
        : 'Android allows about 4 Wi-Fi scans per 2 min';
    final acc = c.fix?.accuracyM;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: glowCard(glow: color, strength: 0.18),
      child: Row(
        children: [
          Radar(active: c.collecting, pulse: c.pulse, size: 64),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: mono(size: 18, color: color)),
                const SizedBox(height: 6),
                Text(
                  acc == null
                      ? 'GPS: searching…'
                      : 'GPS ±${acc.toStringAsFixed(acc < 10 ? 1 : 0)} m'
                            '${acc <= maxStartAccuracyM ? ' · good' : ' · need ≤ ${maxStartAccuracyM.round()} m'}',
                  style: mono(
                    size: 14,
                    color: acc != null && acc <= maxStartAccuracyM
                        ? AppColors.good
                        : AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  scanLine,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({required this.c});

  final SurveyController c;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _Stat(label: 'READINGS', value: '${c.readings}'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _Stat(label: 'STEPS', value: '${c.steps}'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 96),
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            decoration: glowCard(strength: 0.06),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('FLOOR', style: _statLabel),
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    dropdownColor: AppColors.surfaceHigh,
                    value: c.floor.id,
                    style: mono(size: 20, weight: FontWeight.w800),
                    items: [
                      for (final f in c.floors)
                        DropdownMenuItem(
                          value: f.id,
                          child: Text(f.label, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (id) =>
                        c.setFloor(c.floors.firstWhere((f) => f.id == id)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

final TextStyle _statLabel = const TextStyle(
  color: AppColors.textMuted,
  fontSize: 12,
  fontWeight: FontWeight.w700,
  letterSpacing: 1.2,
);

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label $value',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 96),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: glowCard(strength: 0.06),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: _statLabel),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: mono(size: 40, weight: FontWeight.w800),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrailCard extends StatelessWidget {
  const _TrailCard({required this.c});

  final SurveyController c;

  @override
  Widget build(BuildContext context) {
    final rssi = c.latestRssi;
    final level = rssi == null ? null : levelFor(rssi, c.thresholds);
    return Container(
      height: 300,
      decoration: glowCard(strength: 0.08),
      child: Stack(
        children: [
          Positioned.fill(
            child: TrailView(
              points: c.trail,
              x: c.tracker.x,
              y: c.tracker.y,
              heading: c.heading,
            ),
          ),
          Positioned(
            left: 12,
            top: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.background.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: level == null ? AppColors.outline : levelColor(level),
                ),
              ),
              child: Text(
                rssi == null
                    ? '— dBm'
                    : '$rssi dBm · ${levelName(level!).toUpperCase()}',
                style: mono(
                  size: 15,
                  color: level == null
                      ? AppColors.textMuted
                      : levelColor(level),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.t});

  final Thresholds t;

  @override
  Widget build(BuildContext context) {
    Widget item(SignalLevel l, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 12, color: levelColor(l)),
        const SizedBox(width: 6),
        Text(text, style: mono(size: 12, color: AppColors.textPrimary)),
      ],
    );
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        item(SignalLevel.good, 'Good ≥ ${t.goodDbm}'),
        item(SignalLevel.fair, 'Fair ${t.goodDbm} to ${t.deadDbm}'),
        item(SignalLevel.dead, 'Dead < ${t.deadDbm} dBm'),
      ],
    );
  }
}

class _SyncLine extends StatelessWidget {
  const _SyncLine({required this.c});

  final SurveyController c;

  @override
  Widget build(BuildContext context) {
    final failing = c.syncError != null;
    final text = failing
        ? 'Sync: ${c.pending} waiting · ${c.syncError}'
        : c.pending == 0
        ? 'Sync: all saved to the server'
        : 'Sync: ${c.pending} waiting';
    return Row(
      children: [
        Icon(
          failing
              ? Icons.cloud_off
              : c.pending == 0
              ? Icons.cloud_done
              : Icons.cloud_upload,
          size: 18,
          color: failing ? AppColors.fair : AppColors.textMuted,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: failing ? AppColors.fair : AppColors.textMuted,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.c, required this.onEnd});

  final SurveyController c;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    switch (c.phase) {
      case SurveyPhase.acquiring:
      case SurveyPhase.ready:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              onPressed: c.gpsGoodEnough ? c.start : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start survey'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Stand where you want the map to start. Near a window or '
              'doorway the GPS fix is usually good enough.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 14),
            ),
          ],
        );
      case SurveyPhase.active:
      case SurveyPhase.paused:
        final paused = c.phase == SurveyPhase.paused;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OutlinedButton.icon(
              onPressed: c.checkpoint,
              icon: const Icon(Icons.place),
              label: const Text('Add checkpoint (fix drift)'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: paused ? c.resume : c.pause,
                    icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                    label: Text(paused ? 'Resume' : 'Pause'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                    ),
                    onPressed: onEnd,
                    icon: const Icon(Icons.stop),
                    label: const Text('End survey'),
                  ),
                ),
              ],
            ),
          ],
        );
      case SurveyPhase.ending:
        return Column(
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 10),
            Text(
              'Uploading ${c.pending} readings, then processing…',
              style: const TextStyle(color: AppColors.textMuted),
            ),
          ],
        );
      case SurveyPhase.endFailed:
        return FilledButton.icon(
          onPressed: onEnd,
          icon: const Icon(Icons.refresh),
          label: const Text('Try finishing again'),
        );
      case SurveyPhase.done:
        return const SizedBox.shrink();
    }
  }
}
