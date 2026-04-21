/// Admin → Apps. One row per deployed app with admin-scope
/// actions wired against `AppAdminService`:
///
///   * **OAuth…** — open [oauthAuthorize] response URL in a browser
///     (for apps that require an external OAuth hand-shake)
///   * **Quota…** — per-app + per-user CRUD via [AdminQuotaDialog]
///   * **Secrets…** — list/set/delete secrets via [AdminSecretsDialog]
///   * **Delete** — admin-scope destructive undeploy via
///     [adminDeleteApp]
///
/// This surface complements the existing "System credentials"
/// (workspace-wide shared creds) and "Quotas" (daemon-wide list)
/// sections — this one zooms INTO a specific app and exposes the
/// knobs that an app owner would normally reach via their own
/// settings, but which admins need to reach across any app.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/app_summary.dart';
import '../../../services/app_admin_service.dart';
import '../../../services/apps_service.dart';
import '../../../theme/app_theme.dart';
import '../../chat/chat_bubbles.dart' show showToast;
import '_section_scaffold.dart';
import 'admin_quota_dialog.dart';
import 'admin_secrets_dialog.dart';

class AdminAppsSection extends StatefulWidget {
  const AdminAppsSection({super.key});

  @override
  State<AdminAppsSection> createState() => _AdminAppsSectionState();
}

class _AdminAppsSectionState extends State<AdminAppsSection> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    AppsService().addListener(_onChange);
    _load();
  }

  @override
  void dispose() {
    AppsService().removeListener(_onChange);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await AppsService().refresh();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  List<AppSummary> get _filtered {
    final apps = AppsService().apps;
    if (_query.isEmpty) return apps;
    final q = _query.toLowerCase();
    return apps
        .where((a) =>
            a.name.toLowerCase().contains(q) ||
            a.appId.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final apps = _filtered;
    return AdminSectionScaffold(
      title: 'admin.apps'.tr(),
      subtitle: 'admin.apps_subtitle'
          .tr(namedArgs: {'n': '${AppsService().apps.length}'}),
      loading: _loading,
      onRefresh: _load,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchBar(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _query = v.trim()),
          ),
          const SizedBox(height: 14),
          if (apps.isEmpty)
            _buildEmpty(c)
          else
            Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < apps.length; i++) ...[
                    _AppRow(app: apps[i], onChanged: _load),
                    if (i < apps.length - 1)
                      Divider(height: 1, color: c.border),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Column(
          children: [
            Icon(Icons.inbox_rounded, size: 36, color: c.textMuted),
            const SizedBox(height: 12),
            Text('admin.apps_empty'.tr(),
                style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: c.textBright)),
          ],
        ),
      );
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.border),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: GoogleFonts.inter(fontSize: 13, color: c.text),
        decoration: InputDecoration(
          prefixIcon: Icon(Icons.search_rounded, size: 16, color: c.textDim),
          hintText: 'admin.apps_filter'.tr(),
          hintStyle: GoogleFonts.inter(fontSize: 12.5, color: c.textDim),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 10),
        ),
      ),
    );
  }
}

class _AppRow extends StatefulWidget {
  final AppSummary app;
  final VoidCallback onChanged;
  const _AppRow({required this.app, required this.onChanged});

  @override
  State<_AppRow> createState() => _AppRowState();
}

class _AppRowState extends State<_AppRow> {
  bool _busy = false;

  Future<void> _launchOAuth() async {
    setState(() => _busy = true);
    final res = await AppAdminService().oauthAuthorize(
      widget.app.appId,
      scope: AdminScope.admin,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final url = res?['authorize_url'] as String? ?? res?['url'] as String?;
    if (url == null || url.isEmpty) {
      showToast(context, 'admin.apps_oauth_none'.tr());
      return;
    }
    final ok = await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
    if (!mounted) return;
    showToast(
        context,
        ok
            ? 'admin.apps_oauth_opened'.tr()
            : 'admin.apps_oauth_failed'.tr(namedArgs: {'url': url}));
  }

  Future<void> _openQuota() async {
    await showDialog(
      context: context,
      builder: (_) => AdminQuotaDialog(
        appId: widget.app.appId,
        appName: widget.app.name,
      ),
    );
    widget.onChanged();
  }

  Future<void> _openSecrets() async {
    await showDialog(
      context: context,
      builder: (_) => AdminSecretsDialog(
        appId: widget.app.appId,
        appName: widget.app.name,
      ),
    );
    widget.onChanged();
  }

  Future<void> _confirmDelete() async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: c.border),
        ),
        title: Text(
            'admin.apps_delete_title'
                .tr(namedArgs: {'name': widget.app.name}),
            style: GoogleFonts.inter(
                fontSize: 15, fontWeight: FontWeight.w700)),
        content: Text(
          'admin.apps_delete_body'.tr(),
          style: GoogleFonts.inter(fontSize: 13, color: c.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: Text('admin.apps_cancel'.tr()),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.red),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: Text('admin.apps_delete'.tr()),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final success =
        await AppAdminService().adminDeleteApp(widget.app.appId);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(
        context,
        success
            ? 'admin.apps_deleted_ok'
                .tr(namedArgs: {'name': widget.app.name})
            : 'admin.apps_delete_failed'.tr());
    if (success) widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [c.blue, c.purple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.app.name.isNotEmpty
                  ? widget.app.name[0].toUpperCase()
                  : '?',
              style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.app.name,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textBright,
                      fontWeight: FontWeight.w600),
                ),
                Text(
                  widget.app.appId,
                  style: GoogleFonts.firaCode(
                      fontSize: 10.5, color: c.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (_busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          else ...[
            _SmallAction(
              icon: Icons.lock_open_outlined,
              tooltip: 'admin.apps_tip_oauth'.tr(),
              onTap: _launchOAuth,
            ),
            _SmallAction(
              icon: Icons.speed_rounded,
              tooltip: 'admin.apps_tip_quota'.tr(),
              onTap: _openQuota,
            ),
            _SmallAction(
              icon: Icons.vpn_key_outlined,
              tooltip: 'admin.apps_tip_secrets'.tr(),
              onTap: _openSecrets,
            ),
            _SmallAction(
              icon: Icons.delete_outline_rounded,
              tooltip: 'admin.apps_tip_delete'.tr(),
              onTap: _confirmDelete,
              danger: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _SmallAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  const _SmallAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = danger ? c.red : c.textMuted;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints:
            const BoxConstraints(minWidth: 30, minHeight: 30),
        onPressed: onTap,
        icon: Icon(icon, color: color),
      ),
    );
  }
}
