/// A user as the admin screens see it (one row of `GET /users`).
class AdminUser {
  const AdminUser({
    required this.id,
    required this.email,
    required this.name,
    required this.role,
    required this.isActive,
    required this.consented,
    this.createdAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> j) => AdminUser(
    id: j['id'] as String,
    email: j['email'] as String,
    name: j['name'] as String,
    role: j['role'] as String,
    isActive: j['is_active'] as bool? ?? true,
    consented: j['consented_at'] != null,
    createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
  );

  final String id;
  final String email;
  final String name;
  final String role;
  final bool isActive;
  final bool consented;
  final DateTime? createdAt;
}

/// One page of `GET /users`.
class UserPage {
  const UserPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  factory UserPage.fromJson(Map<String, dynamic> j) => UserPage(
    items: [
      for (final u in j['items'] as List)
        AdminUser.fromJson(u as Map<String, dynamic>),
    ],
    total: (j['total'] as num).toInt(),
    page: (j['page'] as num).toInt(),
    pageSize: (j['page_size'] as num).toInt(),
  );

  final List<AdminUser> items;
  final int total;
  final int page;
  final int pageSize;

  bool get hasMore => page * pageSize < total;
}

/// The roles an Admin can give, in the order the screen lists them.
const userRoles = ['admin', 'surveyor', 'viewer'];

/// Only Admins see the user management screen; the API checks it too.
bool canManageUsers(String role) => role == 'admin';
