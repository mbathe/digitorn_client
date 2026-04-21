/// Admin → Users. Paginated table backed by the April-2026
/// `/api/admin/users` endpoint (live-validated shape). Rewrites the
/// previous role-only filter with the full 4-axis toolbar the
/// daemon exposes (q + app_id + role + is_active + provider) and a
/// server-side paginator. Row tap opens [_UserDetailDrawer] — a
/// slide-in panel that edits profile / active flag / scoped roles
/// and hosts the danger-zone soft/hard delete.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/app_summary.dart';
import '../../../services/admin_service.dart';
import '../../../services/apps_service.dart';
import '../../../services/auth_service.dart';
import '../../../theme/app_theme.dart';
import '../../common/themed_dialogs.dart';
import '_section_scaffold.dart';

class AdminUsersSection extends StatefulWidget {
  const AdminUsersSection({super.key});

  @override
  State<AdminUsersSection> createState() => _AdminUsersSectionState();
}

class _AdminUsersSectionState extends State<AdminUsersSection> {
  final _svc = AdminService();
  final _searchCtrl = TextEditingController();

  UserFilters _filters = const UserFilters(limit: 50);
  AdminUserListResponse? _page;
  bool _loading = true;
  String? _error;

  List<RoleCatalog> _roles = const [];
  List<AppSummary> _apps = const [];

  @override
  void initState() {
    super.initState();
    _loadCatalogues();
    _loadPage();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCatalogues() async {
    // Roles catalogue — populates the role filter dropdown.
    try {
      final roles = await _svc.listRoles();
      if (!mounted) return;
      setState(() => _roles = roles);
    } on AdminUserException {
      // Non-fatal — role filter just shows defaults.
    }
    // Apps — populates the app-scope filter.
    if (AppsService().apps.isEmpty) {
      await AppsService().refresh();
    }
    if (!mounted) return;
    setState(() => _apps = AppsService().apps);
  }

  Future<void> _loadPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await _svc.listUsersFiltered(_filters);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
      });
    } on AdminUserException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _updateFilters(UserFilters next) {
    setState(() => _filters = next.copyWith(offset: 0));
    _loadPage();
  }

  void _goToPage(int offset) {
    setState(() => _filters = _filters.copyWith(offset: offset));
    _loadPage();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = _page?.total ?? 0;
    return AdminSectionScaffold(
      title: 'admin.section_users'.tr(),
      subtitle: 'admin.users_subtitle'
          .tr(namedArgs: {'n': '$total'}),
      loading: _loading,
      onRefresh: _loadPage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildToolbar(c),
          const SizedBox(height: 14),
          _buildFilterRow(c),
          const SizedBox(height: 14),
          if (_error != null && (_page?.users.isEmpty ?? true))
            _buildError(c)
          else
            _buildTable(c),
          const SizedBox(height: 14),
          if (_page != null) _buildPagination(c),
        ],
      ),
    );
  }

  // ── Toolbar (search) ─────────────────────────────────────────────

  Widget _buildToolbar(AppColors c) {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 15, color: c.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onSubmitted: (v) =>
                  _updateFilters(_filters.copyWith(q: v.trim())),
              onChanged: (v) {
                // Debounce-ish: only refetch on submit to avoid
                // hammering /users on every keypress. Show typed
                // text locally though.
                if (v.trim().isEmpty && _filters.q.isNotEmpty) {
                  _updateFilters(_filters.copyWith(q: ''));
                }
              },
              style: GoogleFonts.inter(fontSize: 12.5, color: c.textBright),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'admin.users_filter_hint'.tr(),
                hintStyle: GoogleFonts.inter(
                    fontSize: 12, color: c.textMuted),
              ),
            ),
          ),
          if (_filters.q.isNotEmpty)
            IconButton(
              tooltip: 'admin.clear'.tr(),
              iconSize: 14,
              icon: Icon(Icons.close_rounded, color: c.textMuted),
              onPressed: () {
                _searchCtrl.clear();
                _updateFilters(_filters.copyWith(q: ''));
              },
            ),
        ],
      ),
    );
  }

  // ── Filter row ──────────────────────────────────────────────────

  Widget _buildFilterRow(AppColors c) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        _FilterDropdown<String?>(
          label: 'admin.users_filter_role'.tr(),
          value: _filters.role,
          items: [
            _FilterDropdownItem(
                value: null, label: 'admin.users_filter_all'.tr()),
            for (final r in _roles)
              _FilterDropdownItem(value: r.name, label: r.name),
          ],
          onChanged: (v) => _updateFilters(
              v == null ? _filters.copyWith(clearRole: true) : _filters.copyWith(role: v)),
        ),
        _FilterDropdown<String?>(
          label: 'admin.users_filter_app'.tr(),
          value: _filters.appId,
          items: [
            _FilterDropdownItem(
                value: null, label: 'admin.users_filter_all'.tr()),
            for (final a in _apps)
              _FilterDropdownItem(value: a.appId, label: a.name),
          ],
          onChanged: (v) => _updateFilters(
              v == null ? _filters.copyWith(clearAppId: true) : _filters.copyWith(appId: v)),
        ),
        _FilterDropdown<bool?>(
          label: 'admin.users_filter_active'.tr(),
          value: _filters.isActive,
          items: [
            _FilterDropdownItem(
                value: null, label: 'admin.users_filter_all'.tr()),
            _FilterDropdownItem(
                value: true, label: 'admin.users_badge_active'.tr()),
            _FilterDropdownItem(
                value: false, label: 'admin.users_badge_disabled'.tr()),
          ],
          onChanged: (v) => _updateFilters(
              v == null ? _filters.copyWith(clearIsActive: true) : _filters.copyWith(isActive: v)),
        ),
        _FilterDropdown<String?>(
          label: 'admin.users_filter_provider'.tr(),
          value: _filters.provider,
          items: const [
            _FilterDropdownItem(value: null, label: 'All'),
            _FilterDropdownItem(value: 'local', label: 'local'),
            _FilterDropdownItem(value: 'google', label: 'google'),
            _FilterDropdownItem(value: 'github', label: 'github'),
            _FilterDropdownItem(value: 'microsoft', label: 'microsoft'),
          ],
          onChanged: (v) => _updateFilters(
              v == null ? _filters.copyWith(clearProvider: true) : _filters.copyWith(provider: v)),
        ),
      ],
    );
  }

  Widget _buildError(AppColors c) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 16, color: c.red),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_error!,
                  style: GoogleFonts.firaCode(
                      fontSize: 11.5, color: c.textMuted)),
            ),
            const SizedBox(width: 14),
            ElevatedButton(
              onPressed: _loadPage,
              child: Text('admin.retry'.tr(),
                  style: GoogleFonts.inter(fontSize: 11)),
            ),
          ],
        ),
      );

  Widget _buildTable(AppColors c) {
    final users = _page?.users ?? const <AdminUser>[];
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        const tableMinWidth = 720.0;
        final needsScroll = constraints.maxWidth < tableMinWidth;
        final table = Column(
          children: [
            const _UsersTableHeader(),
            for (var i = 0; i < users.length; i++) ...[
              _UserRow(
                user: users[i],
                onTap: () => _openDetail(users[i]),
              ),
              if (i < users.length - 1)
                Divider(height: 1, color: c.border),
            ],
            if (users.isEmpty && !_loading)
              Padding(
                padding: const EdgeInsets.all(34),
                child: Text(
                  _filters.q.isNotEmpty
                      ? 'admin.users_no_match'
                          .tr(namedArgs: {'q': _filters.q})
                      : 'admin.users_none'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 12, color: c.textMuted),
                ),
              ),
          ],
        );
        if (!needsScroll) return table;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: SizedBox(width: tableMinWidth, child: table),
        );
      }),
    );
  }

  Widget _buildPagination(AppColors c) {
    final page = _page!;
    final from = page.users.isEmpty ? 0 : page.offset + 1;
    final to = page.offset + page.users.length;
    final currentPage = (page.offset ~/ page.limit) + 1;
    return Row(
      children: [
        Text(
          'admin.users_pagination'.tr(namedArgs: {
            'from': '$from',
            'to': '$to',
            'total': '${page.total}',
          }),
          style: GoogleFonts.firaCode(
              fontSize: 11, color: c.textMuted),
        ),
        const Spacer(),
        OutlinedButton.icon(
          onPressed: page.offset > 0
              ? () => _goToPage((page.offset - page.limit).clamp(0, 1 << 30))
              : null,
          icon: const Icon(Icons.chevron_left_rounded, size: 14),
          label: Text('admin.prev'.tr(),
              style: GoogleFonts.inter(fontSize: 11)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
        const SizedBox(width: 8),
        Text('admin.users_page'.tr(namedArgs: {'n': '$currentPage'}),
            style: GoogleFonts.firaCode(
                fontSize: 11, color: c.textMuted)),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: page.hasMore
              ? () => _goToPage(page.offset + page.limit)
              : null,
          icon: const Icon(Icons.chevron_right_rounded, size: 14),
          label: Text('admin.next'.tr(),
              style: GoogleFonts.inter(fontSize: 11)),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
        ),
      ],
    );
  }

  // ── Open drawer ──────────────────────────────────────────────────

  Future<void> _openDetail(AdminUser user) async {
    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      pageBuilder: (_, _, _) => _UserDetailDrawer(
        user: user,
        availableRoles: _roles,
        apps: _apps,
        onChanged: _loadPage,
      ),
      transitionBuilder: (_, anim, _, child) {
        return SlideTransition(
          position: Tween(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 220),
    );
  }
}

// ─── Filter dropdown ─────────────────────────────────────────────────

class _FilterDropdownItem<T> {
  final T value;
  final String label;
  const _FilterDropdownItem({required this.value, required this.label});
}

class _FilterDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<_FilterDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  const _FilterDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down_rounded, color: c.textMuted),
          style: GoogleFonts.inter(fontSize: 12, color: c.textBright),
          dropdownColor: c.surface,
          hint: Text(label,
              style: GoogleFonts.inter(fontSize: 12, color: c.textMuted)),
          items: [
            for (final it in items)
              DropdownMenuItem<T>(
                value: it.value,
                child: Row(
                  children: [
                    Text(
                      label,
                      style: GoogleFonts.firaCode(
                          fontSize: 9,
                          color: c.textMuted,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(width: 8),
                    Text(it.label,
                        style: GoogleFonts.inter(
                            fontSize: 12, color: c.textBright)),
                  ],
                ),
              ),
          ],
          onChanged: (v) => onChanged(v as T),
        ),
      ),
    );
  }
}

// ─── Table widgets ───────────────────────────────────────────────────

class _UsersTableHeader extends StatelessWidget {
  const _UsersTableHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    TextStyle h() => GoogleFonts.firaCode(
          fontSize: 9.5,
          color: c.textMuted,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Row(
        children: [
          SizedBox(width: 36, child: Text('', style: h())),
          Expanded(
              flex: 4,
              child: Text('admin.users_col_user'.tr(), style: h())),
          Expanded(
              flex: 3,
              child: Text('admin.users_col_roles'.tr(), style: h())),
          Expanded(
              flex: 2,
              child: Text('admin.users_col_last_seen'.tr(), style: h())),
          SizedBox(
              width: 110,
              child: Text('admin.users_col_status'.tr(), style: h())),
        ],
      ),
    );
  }
}

class _UserRow extends StatefulWidget {
  final AdminUser user;
  final VoidCallback onTap;
  const _UserRow({required this.user, required this.onTap});

  @override
  State<_UserRow> createState() => _UserRowState();
}

class _UserRowState extends State<_UserRow> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final u = widget.user;
    final isMe = AuthService().currentUser?.userId == u.userId;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          color: _h ? c.surfaceAlt : Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            children: [
              _Avatar(user: u),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            u.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                fontSize: 12.5,
                                color: c.textBright,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 6),
                          _Pill(
                              label: 'admin.users_badge_you'.tr(),
                              tint: c.blue),
                        ],
                        if (u.provider != null &&
                            u.provider!.isNotEmpty &&
                            u.provider != 'local') ...[
                          const SizedBox(width: 6),
                          _Pill(label: u.provider!, tint: c.purple),
                        ],
                      ],
                    ),
                    if (u.email != null)
                      Text(u.email!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.firaCode(
                              fontSize: 10, color: c.textMuted)),
                  ],
                ),
              ),
              Expanded(
                flex: 3,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 3,
                  children: [
                    for (final r in u.roleAssignments)
                      _RoleChip(
                        label: r.isGlobal ? r.name : '${r.name}@${r.appId}',
                        tint: r.name == 'admin' ? c.purple : c.blue,
                      ),
                    if (u.roleAssignments.isEmpty)
                      _RoleChip(label: 'user', tint: c.textMuted),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  u.lastSeenAt != null ? _ago(u.lastSeenAt!) : '—',
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textMuted),
                ),
              ),
              SizedBox(
                width: 110,
                child: _StatusBadge(active: u.active),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    if (d.inDays < 30) return '${d.inDays}d ago';
    return '${(d.inDays / 30).floor()}mo ago';
  }
}

class _Avatar extends StatelessWidget {
  final AdminUser user;
  const _Avatar({required this.user});

  @override
  Widget build(BuildContext context) {
    final hash = user.userId.hashCode;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            HSLColor.fromAHSL(1, (hash % 360).toDouble(), 0.6, 0.5).toColor(),
            HSLColor.fromAHSL(1, ((hash ~/ 7) % 360).toDouble(), 0.6, 0.4)
                .toColor(),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        _initials(user.label),
        style: GoogleFonts.inter(
            fontSize: 10,
            color: Colors.white,
            fontWeight: FontWeight.w800),
      ),
    );
  }

  static String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'[\s@._-]+'))
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first
          .substring(0, parts.first.length.clamp(0, 2))
          .toUpperCase();
    }
    return (parts[0][0] + parts[1][0]).toUpperCase();
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color tint;
  const _Pill({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(label,
          style: GoogleFonts.firaCode(
              fontSize: 8,
              color: tint,
              fontWeight: FontWeight.w700)),
    );
  }
}

class _RoleChip extends StatelessWidget {
  final String label;
  final Color tint;
  const _RoleChip({required this.label, required this.tint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Text(
        label.toUpperCase(),
        style: GoogleFonts.firaCode(
          fontSize: 8.5,
          color: tint,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool active;
  const _StatusBadge({required this.active});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = active ? c.green : c.red;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          active
              ? 'admin.users_badge_active'.tr()
              : 'admin.users_badge_disabled'.tr(),
          style: GoogleFonts.firaCode(
            fontSize: 9,
            color: tint,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// ─── Detail drawer ───────────────────────────────────────────────────

class _UserDetailDrawer extends StatefulWidget {
  final AdminUser user;
  final List<RoleCatalog> availableRoles;
  final List<AppSummary> apps;
  final VoidCallback onChanged;
  const _UserDetailDrawer({
    required this.user,
    required this.availableRoles,
    required this.apps,
    required this.onChanged,
  });

  @override
  State<_UserDetailDrawer> createState() => _UserDetailDrawerState();
}

class _UserDetailDrawerState extends State<_UserDetailDrawer> {
  late AdminUser _user;
  final _svc = AdminService();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _user = widget.user;
    _nameCtrl = TextEditingController(text: _user.displayName ?? '');
    _emailCtrl = TextEditingController(text: _user.email ?? '');
    _phoneCtrl = TextEditingController(text: _user.phone ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  bool get _isMe =>
      AuthService().currentUser?.userId == _user.userId;

  Future<void> _saveProfile() async {
    final name = _nameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final changes = <String, dynamic>{};
    if (name != (_user.displayName ?? '')) changes['display_name'] = name;
    if (email != (_user.email ?? '')) changes['email'] = email;
    if (phone != (_user.phone ?? '')) changes['phone'] = phone;
    if (changes.isEmpty) return;
    setState(() => _saving = true);
    try {
      final res = await _svc.patchUser(
        _user.userId,
        displayName: changes.containsKey('display_name')
            ? changes['display_name'] as String
            : null,
        email: changes.containsKey('email')
            ? changes['email'] as String
            : null,
        phone: changes.containsKey('phone')
            ? changes['phone'] as String
            : null,
      );
      if (!mounted) return;
      setState(() {
        _user = res.user;
        _saving = false;
      });
      widget.onChanged();
      _toast('admin.users_updated_ok'.tr());
    } on AdminUserException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.message);
    }
  }

  Future<void> _toggleActive(bool newValue) async {
    if (_isMe && !newValue) {
      _toast('admin.users_cannot_disable_self'.tr());
      return;
    }
    setState(() => _saving = true);
    try {
      final res =
          await _svc.patchUser(_user.userId, isActive: newValue);
      if (!mounted) return;
      setState(() {
        _user = res.user;
        _saving = false;
      });
      widget.onChanged();
    } on AdminUserException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.message);
    }
  }

  Future<void> _setRolesForScope(
      String? appId, List<String> roles) async {
    setState(() => _saving = true);
    try {
      final res = await _svc.patchUser(
        _user.userId,
        roles: roles,
        appId: appId,
      );
      if (!mounted) return;
      setState(() {
        _user = res.user;
        _saving = false;
      });
      widget.onChanged();
    } on AdminUserException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.message);
    }
  }

  Future<void> _softDelete() async {
    if (_isMe) {
      _toast('admin.users_cannot_delete_self'.tr());
      return;
    }
    final ok = await showThemedConfirmDialog(
      context,
      title: 'admin.users_soft_delete_confirm_title'.tr(),
      body: 'admin.users_soft_delete_hint'.tr(),
      confirmLabel: 'admin.users_soft_delete'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    try {
      await _svc.deleteUser(_user.userId, hard: false);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onChanged();
    } on AdminUserException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  Future<void> _hardDelete() async {
    if (_isMe) {
      _toast('admin.users_cannot_delete_self'.tr());
      return;
    }
    final ok = await showThemedConfirmDialog(
      context,
      title: 'admin.users_hard_delete_confirm_title'.tr(),
      body: 'admin.users_hard_delete_hint'.tr(),
      confirmLabel: 'admin.users_hard_delete'.tr(),
      destructive: true,
    );
    if (ok != true) return;
    try {
      await _svc.deleteUser(_user.userId, hard: true);
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onChanged();
    } on AdminUserException catch (e) {
      if (!mounted) return;
      _toast(e.message);
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 520,
          height: double.infinity,
          decoration: BoxDecoration(
            color: c.surface,
            border: Border(left: BorderSide(color: c.border)),
          ),
          child: Column(
            children: [
              _buildHeader(c),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
                  children: [
                    _buildIdentity(c),
                    const SizedBox(height: 22),
                    _buildProfile(c),
                    const SizedBox(height: 22),
                    _buildStatus(c),
                    const SizedBox(height: 22),
                    _buildRoles(c),
                    const SizedBox(height: 28),
                    _buildDangerZone(c),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          _Avatar(user: _user),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_user.label,
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: c.textBright)),
                if (_user.email != null)
                  Text(_user.email!,
                      style: GoogleFonts.firaCode(
                          fontSize: 11, color: c.textMuted)),
              ],
            ),
          ),
          if (_saving)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: c.textMuted),
              ),
            ),
          IconButton(
            iconSize: 16,
            icon: Icon(Icons.close_rounded, color: c.textMuted),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentity(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv(c, 'ID', _user.userId),
          if (_user.externalId != null)
            _kv(c, 'external_id', _user.externalId!),
          if (_user.provider != null)
            _kv(c, 'provider', _user.provider!),
          if (_user.createdAt != null)
            _kv(c, 'created_at', _user.createdAt!.toLocal().toString()),
          if (_user.lastSeenAt != null)
            _kv(c, 'last_seen', _user.lastSeenAt!.toLocal().toString()),
        ],
      ),
    );
  }

  Widget _kv(AppColors c, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(k,
                style: GoogleFonts.firaCode(
                    fontSize: 10, color: c.textMuted)),
          ),
          Expanded(
            child: SelectableText(v,
                style: GoogleFonts.firaCode(
                    fontSize: 10.5, color: c.textBright)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(AppColors c, String label) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(label.toUpperCase(),
            style: GoogleFonts.firaCode(
                fontSize: 10,
                color: c.textMuted,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w700)),
      );

  Widget _buildProfile(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(c, 'admin.users_profile_section'.tr()),
        _field(c, 'admin.users_display_name'.tr(), _nameCtrl),
        const SizedBox(height: 10),
        _field(c, 'Email', _emailCtrl),
        const SizedBox(height: 10),
        _field(c, 'admin.users_phone'.tr(), _phoneCtrl),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton(
            onPressed: _saving ? null : _saveProfile,
            child: Text('admin.save'.tr(),
                style: GoogleFonts.inter(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _field(AppColors c, String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      style: GoogleFonts.inter(fontSize: 12.5, color: c.textBright),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.inter(fontSize: 11, color: c.textMuted),
        isDense: true,
        border: OutlineInputBorder(
          borderSide: BorderSide(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  Widget _buildStatus(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(c, 'admin.users_status_section'.tr()),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text('admin.users_active_toggle'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 12.5, color: c.textBright)),
              ),
              Switch(
                value: _user.active,
                onChanged: _saving ? null : (v) => _toggleActive(v),
              ),
            ],
          ),
        ),
        if (_isMe)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('admin.users_cannot_disable_self'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 10.5, color: c.textMuted)),
          ),
      ],
    );
  }

  Widget _buildRoles(AppColors c) {
    final globalNames =
        _user.globalRoles.map((r) => r.name).toSet();
    final appGroups = <String, Set<String>>{};
    for (final r in _user.appScopedRoles) {
      appGroups
          .putIfAbsent(r.appId!, () => <String>{})
          .add(r.name);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(c, 'admin.users_roles_section'.tr()),
        _roleScopeEditor(
          c,
          title: 'admin.users_roles_global'.tr(),
          selected: globalNames,
          onToggle: (name, nowSelected) {
            final next = {...globalNames};
            if (nowSelected) {
              next.add(name);
            } else {
              next.remove(name);
            }
            _setRolesForScope(null, next.toList());
          },
        ),
        for (final entry in appGroups.entries)
          _roleScopeEditor(
            c,
            title: 'admin.users_roles_on'
                .tr(namedArgs: {'app': entry.key}),
            selected: entry.value,
            onToggle: (name, nowSelected) {
              final next = {...entry.value};
              if (nowSelected) {
                next.add(name);
              } else {
                next.remove(name);
              }
              _setRolesForScope(entry.key, next.toList());
            },
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _saving ? null : _pickAppScope,
            icon: const Icon(Icons.add_rounded, size: 14),
            label: Text('admin.users_add_scope'.tr(),
                style: GoogleFonts.inter(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickAppScope() async {
    final alreadyScoped = _user.appScopesWithRoles;
    final candidates = widget.apps
        .where((a) => !alreadyScoped.contains(a.appId))
        .toList();
    if (candidates.isEmpty) {
      _toast('admin.users_no_more_apps'.tr());
      return;
    }
    final c = context.colors;
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        backgroundColor: c.surface,
        title: Text('admin.users_pick_app'.tr(),
            style: GoogleFonts.inter(
                fontSize: 14,
                color: c.textBright,
                fontWeight: FontWeight.w700)),
        children: [
          for (final a in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, a.appId),
              child: Text('${a.name} (${a.appId})',
                  style: GoogleFonts.inter(fontSize: 12, color: c.text)),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final viewer = widget.availableRoles
        .firstWhere(
          (r) => r.name == 'viewer',
          orElse: () => widget.availableRoles.isEmpty
              ? const RoleCatalog(id: '', name: 'viewer')
              : widget.availableRoles.first,
        )
        .name;
    await _setRolesForScope(picked, [viewer]);
  }

  Widget _roleScopeEditor(
    AppColors c, {
    required String title,
    required Set<String> selected,
    required void Function(String name, bool nowSelected) onToggle,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.textMuted,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final r in widget.availableRoles)
                  FilterChip(
                    label: Text(r.name,
                        style: GoogleFonts.inter(fontSize: 11)),
                    selected: selected.contains(r.name),
                    onSelected: _saving
                        ? null
                        : (v) => onToggle(r.name, v),
                    backgroundColor: c.surface,
                    selectedColor: c.accentPrimary.withValues(alpha: 0.15),
                    checkmarkColor: c.accentPrimary,
                    side: BorderSide(color: c.border),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDangerZone(AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle(c, 'admin.users_danger_zone'.tr()),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.red.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: c.red.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _dangerRow(
                c,
                title: 'admin.users_soft_delete'.tr(),
                hint: 'admin.users_soft_delete_hint'.tr(),
                onPressed: _saving || _isMe ? null : _softDelete,
              ),
              const SizedBox(height: 10),
              Divider(height: 1, color: c.red.withValues(alpha: 0.2)),
              const SizedBox(height: 10),
              _dangerRow(
                c,
                title: 'admin.users_hard_delete'.tr(),
                hint: 'admin.users_hard_delete_hint'.tr(),
                onPressed: _saving || _isMe ? null : _hardDelete,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dangerRow(
    AppColors c, {
    required String title,
    required String hint,
    required VoidCallback? onPressed,
  }) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.red,
                      fontWeight: FontWeight.w700)),
              Text(hint,
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textMuted)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: c.red,
            side: BorderSide(color: c.red.withValues(alpha: 0.4)),
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
          ),
          child: Text(title,
              style: GoogleFonts.inter(fontSize: 11)),
        ),
      ],
    );
  }
}
