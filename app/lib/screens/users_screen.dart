import 'dart:async';

import 'package:flutter/material.dart';

import '../data/api_client.dart';
import '../data/session.dart';
import '../data/user_models.dart';
import '../theme.dart';

/// How the user list can be ordered. [value] is the API's `sort`.
enum UserSort {
  newest('-created_at', 'Newest first'),
  nameAsc('name', 'Name A–Z'),
  emailAsc('email', 'Email A–Z');

  const UserSort(this.value, this.label);

  final String value;
  final String label;
}

/// Which accounts to show.
enum UserStatusFilter {
  all(null, 'Any status'),
  active(true, 'Active'),
  inactive(false, 'Inactive');

  const UserStatusFilter(this.isActive, this.label);

  final bool? isActive;
  final String label;
}

/// What an Admin chose in the details sheet.
class _UserAction {
  const _UserAction.role(this.role) : toggleActive = false, delete = false;
  const _UserAction.toggleActive()
    : role = null,
      toggleActive = true,
      delete = false;
  const _UserAction.delete() : role = null, toggleActive = false, delete = true;

  final String? role;
  final bool toggleActive;
  final bool delete;
}

String roleLabel(String role) => switch (role) {
  'admin' => 'Admin',
  'surveyor' => 'Surveyor',
  'viewer' => 'Viewer',
  _ => role,
};

/// Admin-only user management: search and filter the users, change a role,
/// deactivate or reactivate an account, or delete it. The API checks the Admin
/// role on every call; this screen is only offered to Admins.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key, required this.session, this.pageSize = 20});

  final Session session;
  final int pageSize;

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  UserSort _sort = UserSort.newest;
  UserStatusFilter _status = UserStatusFilter.all;
  String? _role;
  final List<AdminUser> _items = [];
  int _total = 0;
  int _page = 0;
  bool _loading = false;
  String? _error;
  int _generation = 0;

  ApiClient get _api => widget.session.api;
  String get _myId => widget.session.user!.id;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<UserPage> _fetch(int page) => _api.userPage(
    q: _search.text,
    role: _role,
    isActive: _status.isActive,
    page: page,
    pageSize: widget.pageSize,
    sort: _sort.value,
  );

  /// Starts again from page 1. A newer call makes an older answer be ignored.
  Future<void> _reload() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _fetch(1);
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
      final page = await _fetch(_page + 1);
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

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _failure(String what, ApiException e) => e.isNetwork
      ? "You're offline. Nothing was changed."
      : '$what: ${e.message}';

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
    Key? actionKey,
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
            key: actionKey,
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

  Future<void> _open(AdminUser u) async {
    final action = await showModalBottomSheet<_UserAction>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceHigh,
      builder: (_) => _UserSheet(user: u, isMe: u.id == _myId),
    );
    if (action == null || !mounted) return;
    if (action.delete) return _delete(u);
    if (action.toggleActive) return _toggleActive(u);
    return _setRole(u, action.role!);
  }

  void _replace(AdminUser updated) {
    final i = _items.indexWhere((x) => x.id == updated.id);
    if (i < 0) return;
    setState(() => _items[i] = updated);
  }

  Future<void> _setRole(AdminUser u, String role) async {
    if (role == u.role) return;
    if (u.role == 'admin') {
      final ok = await _confirm(
        title: 'Make ${u.name} a ${roleLabel(role)}?',
        body:
            '${u.name} will no longer be able to manage users or see '
            "everyone's surveys.",
        action: 'Change role',
        actionKey: const ValueKey('confirm-action'),
      );
      if (!ok || !mounted) return;
    }
    try {
      final updated = await _api.updateUser(u.id, role: role);
      _replace(updated);
      _toast('${u.name} is now a ${roleLabel(role)}.');
    } on ApiException catch (e) {
      _toast(_failure('Role not changed', e));
    }
  }

  Future<void> _toggleActive(AdminUser u) async {
    final deactivate = u.isActive;
    if (deactivate) {
      final ok = await _confirm(
        title: 'Deactivate ${u.name}?',
        body:
            'They will no longer be able to sign in. Their buildings and '
            'surveys stay. You can reactivate the account later.',
        action: 'Deactivate',
        actionKey: const ValueKey('confirm-action'),
      );
      if (!ok || !mounted) return;
    }
    try {
      final updated = await _api.updateUser(u.id, isActive: !deactivate);
      _replace(updated);
      _toast(
        deactivate
            ? '${u.name} was deactivated.'
            : '${u.name} is active again.',
      );
    } on ApiException catch (e) {
      _toast(_failure(deactivate ? 'Not deactivated' : 'Not reactivated', e));
    }
  }

  Future<void> _delete(AdminUser u) async {
    final ok = await _confirm(
      title: 'Delete ${u.name}?',
      body:
          'The account (${u.email}) and everything it owns will be deleted '
          'for good: its buildings, floors and floor plans, and all of its '
          'surveys. This cannot be undone. To keep the data and only stop '
          'them signing in, deactivate the account instead.',
      action: 'Delete user',
      actionKey: const ValueKey('confirm-action'),
    );
    if (!ok || !mounted) return;
    try {
      await _api.deleteUser(u.id);
      if (!mounted) return;
      setState(() {
        _items.removeWhere((x) => x.id == u.id);
        if (_total > 0) _total -= 1;
      });
      _toast('${u.name} was deleted.');
    } on ApiException catch (e) {
      _toast(_failure('Not deleted', e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _reload,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              TextField(
                key: const ValueKey('user-search'),
                controller: _search,
                onChanged: (v) {
                  setState(() {});
                  _onSearchChanged(v);
                },
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _reload(),
                decoration: InputDecoration(
                  hintText: 'Search name or email',
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
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('role-any'),
                    label: const Text('All roles'),
                    selected: _role == null,
                    onSelected: (_) {
                      setState(() => _role = null);
                      _reload();
                    },
                  ),
                  for (final r in userRoles)
                    ChoiceChip(
                      key: ValueKey('role-$r'),
                      label: Text(roleLabel(r)),
                      selected: _role == r,
                      onSelected: (_) {
                        setState(() => _role = r);
                        _reload();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading && _items.isEmpty
                          ? 'Loading…'
                          : '$_total user${_total == 1 ? '' : 's'}',
                      key: const ValueKey('user-total'),
                      style: const TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<UserStatusFilter>(
                      key: const ValueKey('user-status'),
                      value: _status,
                      dropdownColor: AppColors.surfaceHigh,
                      items: [
                        for (final s in UserStatusFilter.values)
                          DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: (s) {
                        if (s == null) return;
                        setState(() => _status = s);
                        _reload();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<UserSort>(
                      key: const ValueKey('user-sort'),
                      value: _sort,
                      dropdownColor: AppColors.surfaceHigh,
                      items: [
                        for (final s in UserSort.values)
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
                    key: const ValueKey('user-error'),
                    style: const TextStyle(
                      color: AppColors.dead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('user-retry'),
                  onPressed: _items.isEmpty ? _reload : _loadMore,
                  child: const Text('Try again'),
                ),
              ],
              if (_loading && _items.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (!_loading && _items.isEmpty && _error == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'No users match.',
                      key: ValueKey('user-empty'),
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  ),
                ),
              for (final u in _items)
                Card(
                  key: ValueKey('user-${u.id}'),
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    title: Text(u.id == _myId ? '${u.name} (you)' : u.name),
                    subtitle: Text(
                      '${u.email}\n${roleLabel(u.role)}'
                      '${u.isActive ? '' : ' · Inactive'}',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(u),
                  ),
                ),
              if (_items.length < _total && _error == null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    key: const ValueKey('user-more'),
                    onPressed: _loading ? null : _loadMore,
                    child: Text(_loading ? 'Loading…' : 'Load more'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The details of one user and what an Admin can do with the account.
class _UserSheet extends StatelessWidget {
  const _UserSheet({required this.user, required this.isMe});

  final AdminUser user;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final joined = user.createdAt?.toLocal().toIso8601String().substring(0, 10);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(user.name, style: Theme.of(context).textTheme.titleLarge),
            Text(
              user.email,
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 4),
            Text(
              [
                user.isActive ? 'Active' : 'Inactive',
                if (joined != null) 'joined $joined',
                if (user.role == 'surveyor')
                  user.consented ? 'consent given' : 'no consent yet',
              ].join(' · '),
              style: const TextStyle(color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            Text('Role', style: title),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final r in userRoles)
                  ChoiceChip(
                    key: ValueKey('set-role-$r'),
                    label: Text(roleLabel(r)),
                    selected: user.role == r,
                    onSelected: isMe || user.role == r
                        ? null
                        : (_) => Navigator.pop(context, _UserAction.role(r)),
                  ),
              ],
            ),
            if (isMe) ...[
              const SizedBox(height: 8),
              const Text(
                'This is your own account. Change your name, password or '
                'delete it under Profile and settings.',
                key: ValueKey('self-note'),
                style: TextStyle(color: AppColors.textMuted),
              ),
            ] else ...[
              const SizedBox(height: 16),
              OutlinedButton(
                key: const ValueKey('toggle-active'),
                onPressed: () =>
                    Navigator.pop(context, const _UserAction.toggleActive()),
                child: Text(
                  user.isActive ? 'Deactivate account' : 'Reactivate account',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const ValueKey('delete-user'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: () =>
                    Navigator.pop(context, const _UserAction.delete()),
                child: const Text('Delete user'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
