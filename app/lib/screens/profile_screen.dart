import 'package:flutter/material.dart';

import '../core/forms.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/session.dart';
import '../theme.dart';

/// Your account and settings (FR-20): name, the signal thresholds that decide
/// "good" and "dead" on your maps, a password change, sign out and deleting
/// the account with all of its data.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.session,
    this.openDb = LocalDb.open,
  });

  final Session session;
  final Future<LocalDb> Function() openDb;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _profileForm = GlobalKey<FormState>();
  final _passwordForm = GlobalKey<FormState>();
  late final TextEditingController _name = TextEditingController(
    text: widget.session.user!.name,
  );
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  late double _good = widget.session.user!.thresholds.goodDbm.toDouble();
  late double _dead = widget.session.user!.thresholds.deadDbm.toDouble();
  bool _savingProfile = false;
  bool _savingPassword = false;
  bool _deleting = false;
  String? _passwordError;

  @override
  void dispose() {
    _name.dispose();
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  bool get _thresholdsOk => _dead < _good;

  bool get _changed {
    final u = widget.session.user!;
    return _name.text.trim() != u.name ||
        _good.round() != u.thresholds.goodDbm ||
        _dead.round() != u.thresholds.deadDbm;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveProfile() async {
    if (!_profileForm.currentState!.validate() || !_thresholdsOk) return;
    setState(() => _savingProfile = true);
    try {
      final u = widget.session.user!;
      final thresholdsChanged =
          _good.round() != u.thresholds.goodDbm ||
          _dead.round() != u.thresholds.deadDbm;
      await widget.session.updateProfile(
        name: _name.text.trim() == u.name ? null : _name.text.trim(),
        goodDbm: thresholdsChanged ? _good.round() : null,
        deadDbm: thresholdsChanged ? _dead.round() : null,
      );
      _toast('Saved.');
    } on ApiException catch (e) {
      _toast(
        e.isNetwork
            ? "You're offline. ${e.message}"
            : 'Not saved: ${e.message}',
      );
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  Future<void> _changePassword() async {
    if (!_passwordForm.currentState!.validate()) return;
    setState(() {
      _savingPassword = true;
      _passwordError = null;
    });
    try {
      await widget.session.api.changePassword(_current.text, _new.text);
      _current.clear();
      _new.clear();
      _confirm.clear();
      _toast('Password changed.');
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _passwordError = e.statusCode == 400
              ? 'The current password is not right.'
              : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _savingPassword = false);
    }
  }

  Future<void> _signOut() async {
    Navigator.of(context).popUntil((r) => r.isFirst);
    await widget.session.signOut();
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => const _DeleteAccountDialog(),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    final session = widget.session;
    try {
      await session.api.deleteAccount();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _toast(
        e.isNetwork
            ? "You're offline. ${e.message}"
            : 'Could not delete the account: ${e.message}',
      );
      return;
    }
    // The server no longer has the account: forget what is on this phone.
    try {
      final db = await widget.openDb();
      await db.clearAll();
    } catch (_) {
      // No local database: nothing to forget.
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((r) => r.isFirst);
    await session.signOut();
  }

  @override
  Widget build(BuildContext context) {
    // Signing out clears the user while this page is still sliding away.
    final user = widget.session.user;
    if (user == null) return const Scaffold();
    final title = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile and settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Form(
              key: _profileForm,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: glowCard(strength: 0.08),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Account', style: title),
                    const SizedBox(height: 8),
                    Text(
                      '${user.email} · ${user.role}',
                      key: const ValueKey('account-line'),
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                    if (user.role == 'surveyor')
                      Text(
                        user.consented
                            ? 'Privacy consent given.'
                            : 'Privacy consent not given yet.',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: const ValueKey('profile-name'),
                      controller: _name,
                      onChanged: (_) => setState(() {}),
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (v) => validateName(v ?? ''),
                    ),
                    const SizedBox(height: 16),
                    Text('Signal thresholds', style: title),
                    const Text(
                      'Decide what counts as a good signal and a dead zone '
                      'on your maps. Existing surveys use the values they '
                      'were processed with.',
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    Text('Good: ${_good.round()} dBm or stronger'),
                    Slider(
                      key: const ValueKey('threshold-good'),
                      value: _good,
                      min: -90,
                      max: -30,
                      divisions: 60,
                      label: '${_good.round()} dBm',
                      onChanged: (v) => setState(() => _good = v),
                    ),
                    Text('Dead: weaker than ${_dead.round()} dBm'),
                    Slider(
                      key: const ValueKey('threshold-dead'),
                      value: _dead,
                      min: -100,
                      max: -40,
                      divisions: 60,
                      label: '${_dead.round()} dBm',
                      onChanged: (v) => setState(() => _dead = v),
                    ),
                    if (!_thresholdsOk)
                      Semantics(
                        liveRegion: true,
                        child: const Text(
                          'Dead must be weaker (lower) than good.',
                          key: ValueKey('threshold-error'),
                          style: TextStyle(
                            color: AppColors.dead,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('save-profile'),
                      onPressed: _savingProfile || !_changed || !_thresholdsOk
                          ? null
                          : _saveProfile,
                      child: Text(_savingProfile ? 'Saving…' : 'Save'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Form(
              key: _passwordForm,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: glowCard(strength: 0.08),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Change password', style: title),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const ValueKey('password-current'),
                      controller: _current,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Current password',
                      ),
                      validator: (v) => (v == null || v.isEmpty)
                          ? 'Enter your current password.'
                          : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const ValueKey('password-new'),
                      controller: _new,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'New password',
                      ),
                      validator: (v) => validateNewPassword(v ?? ''),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      key: const ValueKey('password-confirm'),
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Repeat the new password',
                      ),
                      validator: (v) =>
                          v == _new.text ? null : 'The passwords do not match.',
                    ),
                    if (_passwordError != null) ...[
                      const SizedBox(height: 8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _passwordError!,
                          style: const TextStyle(
                            color: AppColors.dead,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const ValueKey('save-password'),
                      onPressed: _savingPassword ? null : _changePassword,
                      child: Text(
                        _savingPassword ? 'Changing…' : 'Change password',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('sign-out'),
              onPressed: _signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.danger),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Delete account', style: title),
                  const SizedBox(height: 4),
                  const Text(
                    'Removes your account and all of its data: buildings, '
                    'floors, floor plans and surveys.',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    key: const ValueKey('delete-account'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.danger,
                    ),
                    onPressed: _deleting ? null : _deleteAccount,
                    child: Text(_deleting ? 'Deleting…' : 'Delete my account'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "type DELETE" confirmation. It owns its text controller so it is only
/// disposed once the dialog has finished closing.
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surfaceHigh,
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your account and everything it owns will be deleted for good: '
            'your buildings, floors and floor plans, and all your surveys '
            'with their readings, heatmaps and access points. Readings saved '
            'on this phone that were not uploaded yet are removed too. This '
            'cannot be undone.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('delete-confirm-field'),
            controller: _typed,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Type DELETE to confirm',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            minimumSize: const Size(0, 44),
          ),
          onPressed: _typed.text.trim() == 'DELETE'
              ? () => Navigator.pop(context, true)
              : null,
          child: const Text('Delete account'),
        ),
      ],
    );
  }
}
