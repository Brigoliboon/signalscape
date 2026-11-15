import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../theme.dart';
import 'survey_screen.dart';

/// Pick the building and floor to survey, or create a quick one.
class PickScreen extends StatefulWidget {
  const PickScreen({super.key, required this.session});

  final Session session;

  @override
  State<PickScreen> createState() => _PickScreenState();
}

const _newMarker = '__new__';

class _PickScreenState extends State<PickScreen> {
  List<Building>? _buildings;
  Building? _building; // null with _newBuilding set means "create one"
  bool _newBuilding = false;
  List<Floor> _floors = [];
  Floor? _floor;
  bool _newFloor = false;
  bool _busy = false;
  String? _error;

  final _buildingName = TextEditingController();
  final _floorLabel = TextEditingController(text: 'Ground floor');
  final _floorLevel = TextEditingController(text: '0');

  ApiClient get _api => widget.session.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _buildingName.dispose();
    _floorLabel.dispose();
    _floorLevel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _buildings = null;
    });
    try {
      final list = await _api.buildings();
      if (!mounted) return;
      setState(() {
        _buildings = list;
        _newBuilding = list.isEmpty;
      });
      if (list.isNotEmpty) await _selectBuilding(list.first);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _selectBuilding(Building b) async {
    setState(() {
      _building = b;
      _newBuilding = false;
      _floors = [];
      _floor = null;
      _newFloor = false;
    });
    try {
      final detail = await _api.building(b.id);
      if (!mounted) return;
      setState(() {
        _building = detail;
        _floors = detail.floors;
        _floor = detail.floors.isEmpty ? null : detail.floors.first;
        _newFloor = detail.floors.isEmpty;
        if (_newFloor) _suggestNextFloor();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _suggestNextFloor() {
    final next = _floors.isEmpty ? 0 : _floors.last.level + 1;
    _floorLevel.text = '$next';
    _floorLabel.text = next == 0 ? 'Ground floor' : 'Floor $next';
  }

  Future<void> _continue() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var building = _building;
      var floors = List<Floor>.of(_floors);
      var floor = _floor;
      if (_newBuilding) {
        final name = _buildingName.text.trim();
        if (name.isEmpty) throw ApiException(0, 'Give the building a name.');
        building = await _api.createBuilding(name);
        floors = [];
        floor = null;
      }
      if (_newBuilding || _newFloor) {
        final level = int.tryParse(_floorLevel.text.trim());
        final label = _floorLabel.text.trim();
        if (level == null) {
          throw ApiException(0, 'Floor level must be a whole number.');
        }
        if (label.isEmpty) throw ApiException(0, 'Give the floor a label.');
        floor = await _api.createFloor(building!.id, level, label);
        floors = [...floors, floor]..sort((a, b) => a.level.compareTo(b.level));
      }
      if (building == null || floor == null) {
        throw ApiException(0, 'Pick a building and a floor.');
      }
      if (!mounted) return;
      await SurveyScreen.open(
        context,
        session: widget.session,
        building: building,
        floors: floors,
        floor: floor,
      );
      if (mounted && !_newBuilding) await _selectBuilding(building);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.session.user!;
    final buildings = _buildings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New survey'),
        actions: [
          TextButton(
            onPressed: widget.session.signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: buildings == null && _error == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: [
                  Text(
                    'SIGNED IN AS ${user.email.toUpperCase()} · ${user.role.toUpperCase()}',
                    style: mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: glowCard(strength: 0.08),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Where are you surveying?',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (buildings != null) ..._buildingFields(buildings),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: AppColors.dead,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (buildings == null)
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    )
                  else
                    FilledButton(
                      onPressed: _busy ? null : _continue,
                      child: _busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 3),
                            )
                          : const Text('Continue to survey'),
                    ),
                ],
              ),
      ),
    );
  }

  List<Widget> _buildingFields(List<Building> buildings) {
    return [
      DropdownButtonFormField<String>(
        initialValue: _newBuilding ? _newMarker : _building?.id,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Building'),
        items: [
          for (final b in buildings)
            DropdownMenuItem(value: b.id, child: Text(b.name)),
          const DropdownMenuItem(
            value: _newMarker,
            child: Text('+ New building'),
          ),
        ],
        onChanged: _busy
            ? null
            : (v) {
                if (v == _newMarker) {
                  setState(() {
                    _newBuilding = true;
                    _building = null;
                    _floors = [];
                    _floor = null;
                    _newFloor = false;
                    _suggestNextFloor();
                  });
                } else if (v != null) {
                  _selectBuilding(buildings.firstWhere((b) => b.id == v));
                }
              },
      ),
      const SizedBox(height: 16),
      if (_newBuilding) ...[
        TextField(
          controller: _buildingName,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Building name'),
        ),
        const SizedBox(height: 16),
        ..._newFloorFields('First floor'),
      ] else ...[
        DropdownButtonFormField<String>(
          key: ValueKey('floor-${_building?.id}-${_floors.length}'),
          initialValue: _newFloor ? _newMarker : _floor?.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Floor to start on'),
          items: [
            for (final f in _floors)
              DropdownMenuItem(
                value: f.id,
                child: Text('${f.label} (level ${f.level})'),
              ),
            const DropdownMenuItem(
              value: _newMarker,
              child: Text('+ New floor'),
            ),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  if (v == _newMarker) {
                    _newFloor = true;
                    _suggestNextFloor();
                  } else {
                    _newFloor = false;
                    _floor = _floors.firstWhere((f) => f.id == v);
                  }
                }),
        ),
        if (_newFloor) ...[
          const SizedBox(height: 16),
          ..._newFloorFields('New floor'),
        ],
      ],
    ];
  }

  List<Widget> _newFloorFields(String heading) => [
    Text(heading, style: const TextStyle(fontWeight: FontWeight.w700)),
    const SizedBox(height: 8),
    Row(
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: _floorLabel,
            decoration: const InputDecoration(labelText: 'Label'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: TextField(
            controller: _floorLevel,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(labelText: 'Level'),
          ),
        ),
      ],
    ),
  ];
}
