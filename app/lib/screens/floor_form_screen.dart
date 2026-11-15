import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../core/forms.dart';
import '../core/plan_image.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../theme.dart';
import '../widgets/plan_thumb.dart';

/// A plan picked from the phone, already read into memory.
class PickedPlan {
  const PickedPlan(this.bytes);

  final Uint8List bytes;
}

typedef PlanPicker = Future<PickedPlan?> Function();

/// Opens the phone's photo picker (no storage permission needed).
Future<PickedPlan?> pickPlanFromGallery() async {
  final file = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (file == null) return null;
  return PickedPlan(await file.readAsBytes());
}

/// Add a floor to a building, or edit one, including its floor plan image.
/// Pops with the saved [Floor] (also when only the plan upload went through).
class FloorFormScreen extends StatefulWidget {
  const FloorFormScreen({
    super.key,
    required this.session,
    required this.buildingId,
    this.floor,
    this.existingLevels = const [],
    this.pickPlan = pickPlanFromGallery,
  });

  final Session session;
  final String buildingId;
  final Floor? floor;

  /// Levels the building already has, to suggest the next one.
  final List<int> existingLevels;
  final PlanPicker pickPlan;

  @override
  State<FloorFormScreen> createState() => _FloorFormScreenState();
}

class _FloorFormScreenState extends State<FloorFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _label;
  late final TextEditingController _level;
  late final TextEditingController _height;
  late final TextEditingController _width;
  late final TextEditingController _length;
  late Floor? _saved = widget.floor;
  PickedPlan? _plan;
  String? _planError;
  bool _busy = false;
  String? _error;
  int _planVersion = 0;

  bool get _editing => _saved != null;

  @override
  void initState() {
    super.initState();
    final f = widget.floor;
    final next = suggestNextFloor(widget.existingLevels);
    _label = TextEditingController(text: f?.label ?? next.label);
    _level = TextEditingController(text: '${f?.level ?? next.level}');
    _height = TextEditingController(
      text: '${f?.heightM ?? Floor.defaultFloorHeightM}',
    );
    _width = TextEditingController(text: f?.widthM?.toString() ?? '');
    _length = TextEditingController(text: f?.lengthM?.toString() ?? '');
  }

  @override
  void dispose() {
    _label.dispose();
    _level.dispose();
    _height.dispose();
    _width.dispose();
    _length.dispose();
    super.dispose();
  }

  double? _num(TextEditingController c) =>
      c.text.trim().isEmpty ? null : double.parse(c.text.trim());

  Future<void> _choosePlan() async {
    final picked = await widget.pickPlan();
    if (picked == null || !mounted) return;
    final check = checkPlanBytes(picked.bytes);
    setState(() {
      if (check == PlanCheck.ok) {
        _plan = picked;
        _planError = null;
      } else {
        _planError = planCheckMessage(check);
      }
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = widget.session.api;
    try {
      // Saved first, so a failed plan upload does not lose the floor.
      if (_saved == null || _fieldsChanged()) {
        _saved = _saved == null
            ? await api.createFloor(
                widget.buildingId,
                int.parse(_level.text.trim()),
                _label.text.trim(),
                heightM: double.parse(_height.text.trim()),
                widthM: _num(_width),
                lengthM: _num(_length),
              )
            : await api.updateFloor(
                _saved!.id,
                level: int.parse(_level.text.trim()),
                label: _label.text.trim(),
                heightM: double.parse(_height.text.trim()),
                widthM: _num(_width),
                lengthM: _num(_length),
              );
      }
      final plan = _plan;
      if (plan != null) {
        try {
          _saved = await api.uploadPlan(
            _saved!.id,
            plan.bytes,
            planMediaType(plan.bytes)!,
          );
          _plan = null;
          _planVersion++;
        } on ApiException catch (e) {
          if (mounted) {
            setState(
              () => _error =
                  'The floor was saved, but the plan was not uploaded: '
                  '${e.message} Press Save to try the plan again.',
            );
          }
          return;
        }
      }
      if (mounted) Navigator.of(context).pop(_saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _fieldsChanged() {
    final f = _saved!;
    return f.label != _label.text.trim() ||
        f.level != int.parse(_level.text.trim()) ||
        f.heightM != double.parse(_height.text.trim()) ||
        f.widthM != _num(_width) ||
        f.lengthM != _num(_length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit floor' : 'Add floor')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _label,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Label'),
                      validator: (v) => validateFloorLabel(v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: TextFormField(
                      controller: _level,
                      keyboardType: const TextInputType.numberWithOptions(
                        signed: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Level',
                        helperText: '0 = ground',
                      ),
                      validator: (v) => validateFloorLevel(v ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _height,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Floor height (m)',
                  helperText:
                      'Floor to floor, usually 3 to 3.5 m. The barometer '
                      'uses it to tell floors apart.',
                  helperMaxLines: 3,
                ),
                validator: (v) => validateHeight(v ?? ''),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _width,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Width (m)',
                        helperText: 'Optional',
                      ),
                      validator: (v) => validateOptionalSize(v ?? ''),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _length,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Length (m)',
                        helperText: 'Optional',
                      ),
                      validator: (v) => validateOptionalSize(v ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: glowCard(strength: 0.06),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Floor plan',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'PNG or JPEG, up to 5 MB. Shown under the heatmap.',
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_plan != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.memory(
                          _plan!.bytes,
                          height: 160,
                          fit: BoxFit.contain,
                          semanticLabel: 'Chosen floor plan',
                        ),
                      )
                    else if (_saved != null && _saved!.hasPlan)
                      PlanThumb(
                        api: widget.session.api,
                        floor: _saved!,
                        size: 120,
                        cacheBust: _planVersion,
                      ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _choosePlan,
                      icon: const Icon(Icons.image_outlined),
                      label: Text(
                        _plan != null || (_saved?.hasPlan ?? false)
                            ? 'Choose a different plan'
                            : 'Choose floor plan',
                      ),
                    ),
                    if (_planError != null) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _planError!,
                          style: const TextStyle(
                            color: AppColors.dead,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _save,
                child: _busy
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      )
                    : Text(_editing ? 'Save changes' : 'Add floor'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
