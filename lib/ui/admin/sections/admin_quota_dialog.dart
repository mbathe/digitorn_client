/// Admin → Apps → Quota dialog. Structured editor against the
/// daemon's 2026-04 quota schema — replaces the previous raw
/// key/value editor which couldn't produce valid `messages.custom.5h`
/// / `rolling_from_first` / `fixed_monthly` payloads.
///
/// Tabs:
///   * **App-wide** — [QuotaDefinition] applied to everyone by default
///   * **Per-user override** — lookup a user id then edit their
///     override of the same shape; blank = inherits app-wide
///
/// Each tab renders one collapsible panel per known metric
/// (`requests`, `messages`, `tokens_*`, `cost_usd`) plus a shared
/// "Session caps" block (concurrent / per-session / duration).
library;

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../models/quota.dart';
import '../../../services/admin_service.dart';
import '../../../services/app_admin_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;
import '../../settings/widgets/quota_bar_card.dart' show metricLabel, humanWindow;

class AdminQuotaDialog extends StatefulWidget {
  final String appId;
  final String appName;
  const AdminQuotaDialog(
      {super.key, required this.appId, required this.appName});

  @override
  State<AdminQuotaDialog> createState() => _AdminQuotaDialogState();
}

class _AdminQuotaDialogState extends State<AdminQuotaDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _userIdCtrl = TextEditingController();
  final _userSearchCtrl = TextEditingController();

  QuotaResponse? _appQuota;
  QuotaResponse? _userQuota;
  bool _loadingApp = true;
  bool _loadingUser = false;
  bool _saving = false;

  // User picker state — populated from AdminService.listUsersFiltered.
  // `_pickedUser` is the currently-selected AdminUser (drives the
  // header banner); `_userIdCtrl.text` is the id sent to the daemon
  // (also writable manually if the admin types a raw id).
  List<AdminUser> _userResults = const [];
  bool _userSearchLoading = false;
  String? _userSearchError;
  AdminUser? _pickedUser;
  Timer? _searchDebounce;

  // Working copy — what the admin is editing right now for each tab.
  QuotaDefinition _appDraft = const QuotaDefinition();
  QuotaDefinition _userDraft = const QuotaDefinition();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadApp();
    // Eager-load an initial page of users so the picker is populated
    // before the admin starts typing. Scoped to this app when possible
    // (falls back to all users if the daemon sends nothing back).
    _searchUsers('');
  }

  @override
  void dispose() {
    _tabs.dispose();
    _userIdCtrl.dispose();
    _userSearchCtrl.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _searchUsers(q.trim()),
    );
  }

  Future<void> _searchUsers(String q) async {
    setState(() {
      _userSearchLoading = true;
      _userSearchError = null;
    });
    try {
      // First try scoped to this app, then fall back to a global
      // search so a manually-typed query still finds users who have
      // no role on this app yet (quotas can be set for them too).
      var res = await AdminService().listUsersFiltered(
        UserFilters(q: q, appId: widget.appId, limit: 25),
      );
      if (res.users.isEmpty) {
        res = await AdminService()
            .listUsersFiltered(UserFilters(q: q, limit: 25));
      }
      if (!mounted) return;
      setState(() {
        _userResults = res.users;
        _userSearchLoading = false;
      });
    } on AdminUserException catch (e) {
      if (!mounted) return;
      setState(() {
        _userResults = const [];
        _userSearchError = e.message;
        _userSearchLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _userResults = const [];
        _userSearchError = e.toString();
        _userSearchLoading = false;
      });
    }
  }

  void _pickUser(AdminUser u) {
    setState(() {
      _pickedUser = u;
      _userIdCtrl.text = u.userId;
    });
    _loadUser();
  }

  void _clearPickedUser() {
    setState(() {
      _pickedUser = null;
      _userIdCtrl.text = '';
      _userQuota = null;
      _userDraft = const QuotaDefinition();
    });
  }

  Future<void> _loadApp() async {
    setState(() => _loadingApp = true);
    final q = await AppAdminService()
        .getAppQuotaTyped(widget.appId, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() {
      _appQuota = q;
      _appDraft = q?.quota ?? q?.effective ?? const QuotaDefinition();
      _loadingApp = false;
    });
  }

  Future<void> _loadUser() async {
    final uid = _userIdCtrl.text.trim();
    if (uid.isEmpty) return;
    setState(() => _loadingUser = true);
    final q = await AppAdminService().getUserQuotaTyped(
      widget.appId,
      uid,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() {
      _userQuota = q;
      _userDraft = q?.quota ?? const QuotaDefinition();
      _loadingUser = false;
    });
  }

  Future<void> _saveApp() async {
    setState(() => _saving = true);
    final res = await AppAdminService().setAppQuotaTyped(
      widget.appId,
      _appDraft,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res != null) {
      showToast(context, 'admin.qd_saved'.tr());
      _appQuota = res;
      // The daemon can return `effective:null` right after a PUT;
      // re-fetch to surface the merged view. Fire-and-forget with
      // an error trap so a silent refresh failure is at least logged.
      unawaited(_loadApp().catchError(
          (e) => debugPrint('qd: _loadApp after save failed: $e')));
    } else {
      showToast(context, 'admin.qd_save_failed'.tr());
    }
  }

  Future<void> _saveUser() async {
    final uid = _userIdCtrl.text.trim();
    if (uid.isEmpty) return;
    setState(() => _saving = true);
    final res = await AppAdminService().setUserQuotaTyped(
      widget.appId,
      uid,
      _userDraft,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (res != null) {
      showToast(context,
          'admin.qd_user_saved'.tr(namedArgs: {'uid': uid}));
      _userQuota = res;
    } else {
      showToast(context, 'admin.qd_save_failed'.tr());
    }
  }

  Future<void> _clearApp() async {
    final ok = await _confirm(
        'admin.qd_clear_app_confirm'.tr(namedArgs: {'name': widget.appName}));
    if (ok != true) return;
    setState(() => _saving = true);
    final done = await AppAdminService()
        .clearQuota(widget.appId, scope: AdminScope.admin);
    if (!mounted) return;
    setState(() => _saving = false);
    showToast(context,
        done ? 'admin.qd_cleared'.tr() : 'admin.qd_clear_failed'.tr());
    if (done) {
      setState(() => _appDraft = const QuotaDefinition());
      unawaited(_loadApp().catchError(
          (e) => debugPrint('qd: _loadApp after clear failed: $e')));
    }
  }

  Future<void> _clearUser() async {
    final uid = _userIdCtrl.text.trim();
    if (uid.isEmpty) return;
    final ok = await _confirm(
        'admin.qd_clear_user_confirm'.tr(namedArgs: {'uid': uid}));
    if (ok != true) return;
    setState(() => _saving = true);
    final done = await AppAdminService().clearUserQuota(
      widget.appId,
      uid,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    showToast(context,
        done ? 'admin.qd_cleared'.tr() : 'admin.qd_clear_failed'.tr());
    if (done) {
      setState(() {
        _userDraft = const QuotaDefinition();
        _userQuota = null;
      });
    }
  }

  Future<bool?> _confirm(String body) async {
    final c = context.colors;
    return showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text('admin.qd_confirm'.tr(),
            style: GoogleFonts.inter(
                fontSize: 14, fontWeight: FontWeight.w700)),
        content: Text(body,
            style: GoogleFonts.inter(fontSize: 12, color: c.text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text('admin.qd_cancel'.tr())),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: c.red),
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('admin.qd_ok'.tr())),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: 720, maxHeight: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(c),
            Divider(height: 1, color: c.border),
            TabBar(
              controller: _tabs,
              indicatorColor: c.accentPrimary,
              labelColor: c.textBright,
              unselectedLabelColor: c.textMuted,
              labelStyle: GoogleFonts.inter(
                  fontSize: 12, fontWeight: FontWeight.w700),
              tabs: [
                Tab(text: 'admin.qd_tab_app'.tr()),
                Tab(text: 'admin.qd_tab_user'.tr()),
              ],
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildAppTab(c),
                  _buildUserTab(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 10, 12),
        child: Row(
          children: [
            Icon(Icons.speed_rounded, size: 18, color: c.blue),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'admin.qd_title'
                        .tr(namedArgs: {'name': widget.appName}),
                    style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: c.textBright),
                  ),
                  Text(widget.appId,
                      style: GoogleFonts.firaCode(
                          fontSize: 10.5, color: c.textDim)),
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
              onPressed: () => Navigator.of(context).pop(),
              icon: Icon(Icons.close_rounded,
                  size: 16, color: c.textMuted),
            ),
          ],
        ),
      );

  Widget _buildAppTab(AppColors c) {
    if (_loadingApp) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        if (_appQuota?.updatedAt != null)
          _UpdatedAtBanner(
              updatedAt: _appQuota!.updatedAt!,
              updatedBy: _appQuota!.updatedBy),
        const SizedBox(height: 14),
        _QuotaDefinitionEditor(
          initial: _appDraft,
          onChanged: (d) => setState(() => _appDraft = d),
        ),
        const SizedBox(height: 18),
        _SaveRow(
          onCancel: () {
            setState(() => _appDraft =
                _appQuota?.quota ?? const QuotaDefinition());
          },
          onSave: _saving ? null : _saveApp,
          onClear: _saving ? null : _clearApp,
          destructive: true,
          clearLabel: 'admin.qd_clear_app'.tr(),
        ),
      ],
    );
  }

  Widget _buildUserTab(AppColors c) {
    final hasPicked = _pickedUser != null ||
        _userIdCtrl.text.trim().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        if (!hasPicked) _buildUserPicker(c),
        if (hasPicked) _buildPickedHeader(c),
        const SizedBox(height: 14),
        if (hasPicked) ...[
          if (_loadingUser)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            )
          else ...[
            if (_userQuota?.updatedAt != null)
              _UpdatedAtBanner(
                  updatedAt: _userQuota!.updatedAt!,
                  updatedBy: _userQuota!.updatedBy),
            const SizedBox(height: 14),
            _QuotaDefinitionEditor(
              initial: _userDraft,
              onChanged: (d) => setState(() => _userDraft = d),
            ),
            const SizedBox(height: 18),
            _SaveRow(
              onCancel: () => setState(() =>
                  _userDraft = _userQuota?.quota ?? const QuotaDefinition()),
              onSave: _saving ? null : _saveUser,
              onClear: _saving ? null : _clearUser,
              destructive: true,
              clearLabel: 'admin.qd_clear_user'.tr(),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildUserPicker(AppColors c) {
    return Container(
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Icon(Icons.person_search_rounded,
                    size: 16, color: c.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _userSearchCtrl,
                    onChanged: _onSearchChanged,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: c.textBright),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'admin.qd_user_search_hint'.tr(),
                      hintStyle: GoogleFonts.inter(
                          fontSize: 11.5, color: c.textMuted),
                    ),
                  ),
                ),
                if (_userSearchLoading)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: c.textMuted),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          if (_userSearchError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _userSearchError!,
                style:
                    GoogleFonts.inter(fontSize: 11.5, color: c.red),
              ),
            )
          else if (_userResults.isEmpty && !_userSearchLoading)
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                'admin.qd_user_search_empty'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11.5, color: c.textMuted),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _userResults.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: c.border),
                itemBuilder: (_, i) =>
                    _userRow(c, _userResults[i]),
              ),
            ),
          Divider(height: 1, color: c.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: _manualIdRow(c),
          ),
        ],
      ),
    );
  }

  Widget _userRow(AppColors c, AdminUser u) {
    return InkWell(
      onTap: () => _pickUser(u),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _userAvatar(c, u),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                              fontWeight: FontWeight.w600,
                              color: c.textBright),
                        ),
                      ),
                      if (u.isAdmin) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'admin.qd_user_admin'.tr(),
                          child: Icon(Icons.shield_rounded,
                              size: 12, color: c.blue),
                        ),
                      ],
                      if (!u.active) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'admin.qd_user_inactive'.tr(),
                          child: Icon(Icons.block_rounded,
                              size: 12, color: c.orange),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    u.email ?? u.userId,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.firaCode(
                        fontSize: 10, color: c.textDim),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _userAvatar(AppColors c, AdminUser u) {
    final initials = _initialsFor(u);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.surface,
        shape: BoxShape.circle,
        border: Border.all(color: c.border),
      ),
      child: Text(
        initials,
        style: GoogleFonts.firaCode(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: c.textMuted),
      ),
    );
  }

  static String _initialsFor(AdminUser u) {
    final src = (u.displayName?.trim().isNotEmpty ?? false)
        ? u.displayName!
        : (u.email ?? u.userId);
    final parts = src
        .split(RegExp(r'[\s@._-]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.substring(0, 1).toUpperCase();
    }
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }


  Widget _manualIdRow(AppColors c) {
    return Row(
      children: [
        Icon(Icons.edit_rounded, size: 13, color: c.textDim),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _userIdCtrl,
            style: GoogleFonts.firaCode(
                fontSize: 11, color: c.textBright),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              hintText: 'admin.qd_user_id_hint'.tr(),
              hintStyle: GoogleFonts.inter(
                  fontSize: 10.5, color: c.textDim),
            ),
            onSubmitted: (_) => _loadUser(),
          ),
        ),
        TextButton(
          onPressed: _userIdCtrl.text.trim().isEmpty ? null : _loadUser,
          style: TextButton.styleFrom(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            minimumSize: const Size(0, 28),
          ),
          child: Text('admin.qd_lookup'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 11, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }

  Widget _buildPickedHeader(AppColors c) {
    final u = _pickedUser;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          if (u != null) ...[
            _userAvatar(c, u),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(u.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: c.textBright)),
                  Text(u.userId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.firaCode(
                          fontSize: 10, color: c.textDim)),
                ],
              ),
            ),
          ] else ...[
            Icon(Icons.person_rounded, size: 18, color: c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(_userIdCtrl.text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: c.textBright)),
            ),
          ],
          TextButton.icon(
            onPressed: _clearPickedUser,
            icon: Icon(Icons.swap_horiz_rounded,
                size: 14, color: c.blue),
            label: Text('admin.qd_change_user'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: c.blue)),
          ),
        ],
      ),
    );
  }
}

// ─── Structured editor widget ────────────────────────────────────

class _QuotaDefinitionEditor extends StatefulWidget {
  final QuotaDefinition initial;
  final ValueChanged<QuotaDefinition> onChanged;
  const _QuotaDefinitionEditor({
    required this.initial,
    required this.onChanged,
  });

  @override
  State<_QuotaDefinitionEditor> createState() =>
      _QuotaDefinitionEditorState();
}

class _QuotaDefinitionEditorState extends State<_QuotaDefinitionEditor> {
  late Map<String, Map<String, QuotaRule>> _metricWindows;
  int? _concurrent;
  int? _msgsPerSession;
  int? _durationSec;

  @override
  void initState() {
    super.initState();
    _metricWindows = {
      for (final m in widget.initial.metricWindows.entries)
        m.key: Map<String, QuotaRule>.from(m.value),
    };
    _concurrent = widget.initial.concurrentSessions;
    _msgsPerSession = widget.initial.messagesPerSession;
    _durationSec = widget.initial.sessionDurationSeconds;
  }

  void _emit() {
    widget.onChanged(QuotaDefinition(
      metricWindows: _metricWindows,
      concurrentSessions: _concurrent,
      messagesPerSession: _msgsPerSession,
      sessionDurationSeconds: _durationSec,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final metric in kKnownQuotaMetrics)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _MetricPanel(
              metric: metric,
              windows: _metricWindows[metric] ?? const {},
              onWindowsChanged: (next) {
                setState(() {
                  if (next.isEmpty) {
                    _metricWindows.remove(metric);
                  } else {
                    _metricWindows[metric] = next;
                  }
                });
                _emit();
              },
            ),
          ),
        _SessionCapsPanel(
          concurrent: _concurrent,
          messagesPerSession: _msgsPerSession,
          durationSeconds: _durationSec,
          onChanged: (c, m, d) {
            setState(() {
              _concurrent = c;
              _msgsPerSession = m;
              _durationSec = d;
            });
            _emit();
          },
        ),
      ],
    );
  }
}

class _MetricPanel extends StatelessWidget {
  final String metric;
  final Map<String, QuotaRule> windows;
  final ValueChanged<Map<String, QuotaRule>> onWindowsChanged;
  const _MetricPanel({
    required this.metric,
    required this.windows,
    required this.onWindowsChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(metricLabel(metric),
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: c.textBright)),
              ),
              IconButton(
                tooltip: 'admin.qd_add_window'.tr(),
                iconSize: 14,
                icon:
                    Icon(Icons.add_rounded, color: c.accentPrimary),
                onPressed: () => _pickAndAddWindow(context),
              ),
            ],
          ),
          if (windows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text('admin.qd_no_rules'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 11, color: c.textMuted)),
            )
          else
            for (final entry in windows.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key)))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: _WindowRow(
                  window: entry.key,
                  rule: entry.value,
                  isCost: metric == 'cost_usd',
                  onChange: (next) {
                    final m = Map<String, QuotaRule>.from(windows);
                    m[entry.key] = next;
                    onWindowsChanged(m);
                  },
                  onRemove: () {
                    final m = Map<String, QuotaRule>.from(windows);
                    m.remove(entry.key);
                    onWindowsChanged(m);
                  },
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _pickAndAddWindow(BuildContext context) async {
    final res = await showDialog<({String window, QuotaRule rule})>(
      context: context,
      builder: (_) => _AddWindowDialog(
        metric: metric,
        existing: windows.keys.toSet(),
      ),
    );
    if (res == null) return;
    final m = Map<String, QuotaRule>.from(windows);
    m[res.window] = res.rule;
    onWindowsChanged(m);
  }
}

class _WindowRow extends StatefulWidget {
  final String window;
  final QuotaRule rule;
  final bool isCost;
  final ValueChanged<QuotaRule> onChange;
  final VoidCallback onRemove;
  const _WindowRow({
    required this.window,
    required this.rule,
    required this.isCost,
    required this.onChange,
    required this.onRemove,
  });

  @override
  State<_WindowRow> createState() => _WindowRowState();
}

class _WindowRowState extends State<_WindowRow> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.isCost
          ? widget.rule.limit.toStringAsFixed(2)
          : widget.rule.limit.round().toString(),
    );
  }

  @override
  void didUpdateWidget(_WindowRow old) {
    super.didUpdateWidget(old);
    if (old.rule.limit != widget.rule.limit) {
      _ctrl.text = widget.isCost
          ? widget.rule.limit.toStringAsFixed(2)
          : widget.rule.limit.round().toString();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            humanWindow(widget.window),
            style: GoogleFonts.firaCode(
                fontSize: 11, color: c.text),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 110,
          child: TextField(
            controller: _ctrl,
            keyboardType: TextInputType.numberWithOptions(
                decimal: widget.isCost),
            inputFormatters: widget.isCost
                ? const [] // allow decimals
                : [FilteringTextInputFormatter.digitsOnly],
            onChanged: (v) {
              final parsed = double.tryParse(v);
              if (parsed != null) {
                widget.onChange(widget.rule.copyWith(limit: parsed));
              }
            },
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textBright),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              prefixText: widget.isCost ? '\$ ' : null,
              prefixStyle: GoogleFonts.firaCode(
                  fontSize: 11, color: c.textMuted),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: DropdownButtonFormField<ResetStrategy>(
            initialValue: widget.rule.reset,
            isDense: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
            ),
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textBright),
            items: [
              for (final r in ResetStrategy.values)
                DropdownMenuItem(
                  value: r,
                  child: Text(r.toJson(),
                      style: GoogleFonts.firaCode(fontSize: 11)),
                ),
            ],
            onChanged: (v) =>
                v == null ? null : widget.onChange(widget.rule.copyWith(reset: v)),
          ),
        ),
        IconButton(
          tooltip: 'admin.qd_remove'.tr(),
          iconSize: 14,
          icon: Icon(Icons.close_rounded, color: c.red),
          onPressed: widget.onRemove,
        ),
      ],
    );
  }
}

class _AddWindowDialog extends StatefulWidget {
  final String metric;
  final Set<String> existing;
  const _AddWindowDialog({required this.metric, required this.existing});

  @override
  State<_AddWindowDialog> createState() => _AddWindowDialogState();
}

class _AddWindowDialogState extends State<_AddWindowDialog> {
  String _windowType = 'per_day';
  final _customCountCtrl = TextEditingController(text: '5');
  String _customUnit = 'h';
  final _limitCtrl = TextEditingController();
  ResetStrategy _reset = ResetStrategy.fixed;

  static const _quickCustom = [
    ('5m', '5m'),
    ('30m', '30m'),
    ('1h', '1h'),
    ('5h', '5h'),
    ('12h', '12h'),
    ('1d', '1d'),
    ('3d', '3d'),
    ('7d', '7d'),
    ('30d', '30d'),
  ];

  @override
  void dispose() {
    _customCountCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  String get _resolvedWindow {
    if (_windowType == 'custom') {
      final count = int.tryParse(_customCountCtrl.text) ?? 1;
      return '$count$_customUnit';
    }
    return _windowType;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isCost = widget.metric == 'cost_usd';
    return AlertDialog(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: c.border),
      ),
      title: Text('admin.qd_add_window_title'
          .tr(namedArgs: {'metric': metricLabel(widget.metric)})),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('admin.qd_window'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final w in kNamedWindows)
                    _windowChip(c, w, label: humanWindow(w)),
                  for (final (v, label) in _quickCustom)
                    _windowChip(c, v, label: label),
                  _windowChip(c, 'custom',
                      label: 'admin.qd_custom'.tr()),
                ],
              ),
              if (_windowType == 'custom') ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _customCountCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                            isDense: true, border: OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _customUnit,
                      items: const [
                        DropdownMenuItem(value: 'm', child: Text('min')),
                        DropdownMenuItem(value: 'h', child: Text('h')),
                        DropdownMenuItem(value: 'd', child: Text('d')),
                        DropdownMenuItem(value: 'w', child: Text('w')),
                      ],
                      onChanged: (v) => setState(() => _customUnit = v ?? 'h'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Text('admin.qd_limit'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const SizedBox(height: 6),
              TextField(
                controller: _limitCtrl,
                keyboardType:
                    TextInputType.numberWithOptions(decimal: isCost),
                inputFormatters: isCost
                    ? const []
                    : [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  isDense: true,
                  prefixText: isCost ? '\$ ' : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Text('admin.qd_reset_strategy'.tr(),
                  style: GoogleFonts.firaCode(
                      fontSize: 10,
                      color: c.textMuted,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8)),
              const SizedBox(height: 6),
              for (final r in ResetStrategy.values)
                InkWell(
                  onTap: () => setState(() => _reset = r),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _reset == r
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          size: 16,
                          color: _reset == r
                              ? c.accentPrimary
                              : c.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(r.toJson(),
                                  style: GoogleFonts.firaCode(
                                      fontSize: 12, color: c.text)),
                              Text(_resetStrategyHint(r),
                                  style: GoogleFonts.inter(
                                      fontSize: 10.5,
                                      color: c.textMuted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('admin.qd_cancel'.tr())),
        FilledButton(
          onPressed: () {
            final window = _resolvedWindow;
            if (window.isEmpty) return;
            if (widget.existing.contains(window)) {
              Navigator.pop(context);
              return;
            }
            final limit = double.tryParse(_limitCtrl.text);
            if (limit == null || limit <= 0) return;
            Navigator.pop(
              context,
              (
                window: window,
                rule: QuotaRule(limit: limit, reset: _reset)
              ),
            );
          },
          child: Text('admin.qd_add'.tr()),
        ),
      ],
    );
  }

  Widget _windowChip(AppColors c, String value, {required String label}) {
    final selected = _windowType == value;
    return ChoiceChip(
      label: Text(label,
          style: GoogleFonts.firaCode(fontSize: 11)),
      selected: selected,
      onSelected: (_) => setState(() => _windowType = value),
      selectedColor: c.accentPrimary.withValues(alpha: 0.15),
      backgroundColor: c.surface,
      side: BorderSide(color: c.border),
    );
  }

  String _resetStrategyHint(ResetStrategy r) {
    switch (r) {
      case ResetStrategy.fixed:
        return 'admin.qd_reset_hint_fixed'.tr();
      case ResetStrategy.fixedDaily:
        return 'admin.qd_reset_hint_fixed_daily'.tr();
      case ResetStrategy.fixedWeekly:
        return 'admin.qd_reset_hint_fixed_weekly'.tr();
      case ResetStrategy.fixedMonthly:
        return 'admin.qd_reset_hint_fixed_monthly'.tr();
      case ResetStrategy.rollingFromFirst:
        return 'admin.qd_reset_hint_rolling'.tr();
    }
  }
}

class _SessionCapsPanel extends StatefulWidget {
  final int? concurrent;
  final int? messagesPerSession;
  final int? durationSeconds;
  final void Function(int?, int?, int?) onChanged;
  const _SessionCapsPanel({
    required this.concurrent,
    required this.messagesPerSession,
    required this.durationSeconds,
    required this.onChanged,
  });

  @override
  State<_SessionCapsPanel> createState() => _SessionCapsPanelState();
}

class _SessionCapsPanelState extends State<_SessionCapsPanel> {
  late final TextEditingController _concurrent;
  late final TextEditingController _msg;
  late final TextEditingController _dur;

  @override
  void initState() {
    super.initState();
    _concurrent = TextEditingController(text: widget.concurrent?.toString() ?? '');
    _msg = TextEditingController(
        text: widget.messagesPerSession?.toString() ?? '');
    _dur = TextEditingController(text: widget.durationSeconds?.toString() ?? '');
  }

  @override
  void dispose() {
    _concurrent.dispose();
    _msg.dispose();
    _dur.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(
      int.tryParse(_concurrent.text),
      int.tryParse(_msg.text),
      int.tryParse(_dur.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('admin.qd_session_caps'.tr(),
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: c.textBright)),
          const SizedBox(height: 12),
          _capRow(c, 'admin.qd_concurrent_sessions'.tr(), _concurrent),
          const SizedBox(height: 8),
          _capRow(c, 'admin.qd_messages_per_session'.tr(), _msg),
          const SizedBox(height: 8),
          _capRow(c, 'admin.qd_session_duration_secs'.tr(), _dur),
        ],
      ),
    );
  }

  Widget _capRow(AppColors c, String label, TextEditingController ctrl) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style:
                  GoogleFonts.inter(fontSize: 12, color: c.text)),
        ),
        SizedBox(
          width: 110,
          child: TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onChanged: (_) => _emit(),
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textBright),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: BorderSide(color: c.border),
              ),
              hintText: '—',
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Supporting widgets ──────────────────────────────────────────

class _UpdatedAtBanner extends StatelessWidget {
  final DateTime updatedAt;
  final String? updatedBy;
  const _UpdatedAtBanner(
      {required this.updatedAt, required this.updatedBy});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = DateTime.now().toUtc().difference(updatedAt.toUtc());
    final ago = d.inMinutes < 1
        ? 'admin.qd_ago_just_now'.tr()
        : d.inHours < 1
            ? 'admin.qd_ago_minutes'.tr(namedArgs: {'n': '${d.inMinutes}'})
            : d.inDays < 1
                ? 'admin.qd_ago_hours'.tr(namedArgs: {'n': '${d.inHours}'})
                : 'admin.qd_ago_days'.tr(namedArgs: {'n': '${d.inDays}'});
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 12, color: c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'admin.qd_updated_at'.tr(namedArgs: {
                'when': ago,
                'by': updatedBy ?? 'admin.qd_unknown_user'.tr(),
              }),
              style: GoogleFonts.firaCode(
                  fontSize: 10, color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SaveRow extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback? onSave;
  final VoidCallback? onClear;
  final String? clearLabel;
  final bool destructive;
  const _SaveRow({
    required this.onCancel,
    required this.onSave,
    this.onClear,
    this.clearLabel,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        if (onClear != null)
          OutlinedButton.icon(
            onPressed: onClear,
            icon:
                const Icon(Icons.delete_sweep_outlined, size: 14),
            label: Text(clearLabel ?? 'admin.qd_clear'.tr()),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.red,
              side: BorderSide(color: c.red.withValues(alpha: 0.4)),
            ),
          ),
        const Spacer(),
        TextButton(
          onPressed: onCancel,
          child: Text('admin.qd_reset'.tr()),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: onSave,
          icon: const Icon(Icons.save_rounded, size: 14),
          label: Text('admin.qd_save'.tr()),
        ),
      ],
    );
  }
}
