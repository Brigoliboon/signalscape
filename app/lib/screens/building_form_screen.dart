import 'package:flutter/material.dart';

import '../core/forms.dart';
import '../data/api_client.dart';
import '../data/models.dart';
import '../data/session.dart';
import '../theme.dart';

/// Add a building, or edit one. Pops with the saved [Building].
class BuildingFormScreen extends StatefulWidget {
  const BuildingFormScreen({super.key, required this.session, this.building});

  final Session session;
  final Building? building;

  @override
  State<BuildingFormScreen> createState() => _BuildingFormScreenState();
}

class _BuildingFormScreenState extends State<BuildingFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.building?.name);
  late final _address = TextEditingController(text: widget.building?.address);
  late final _description = TextEditingController(
    text: widget.building?.description,
  );
  bool _busy = false;
  String? _error;

  bool get _editing => widget.building != null;

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _opt(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = widget.session.api;
      final saved = _editing
          ? await api.updateBuilding(
              widget.building!.id,
              name: _name.text.trim(),
              address: _opt(_address),
              description: _opt(_description),
            )
          : await api.createBuilding(
              _name.text.trim(),
              address: _opt(_address),
              description: _opt(_description),
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit building' : 'Add building')),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Building name'),
                validator: (v) => validateBuildingName(v ?? ''),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _address,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Address (optional)',
                ),
                validator: (v) => validateAddress(v ?? ''),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _description,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
                validator: (v) => validateDescription(v ?? ''),
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
                    : Text(_editing ? 'Save changes' : 'Add building'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
