/// Admin console — single shell that hosts every admin-only
/// surface the daemon exposes. Uses the same left-sidebar pattern
/// as the Settings page so the muscle memory carries over.
///
/// Sections:
///   * Overview              — workspace stats + recent admin audit
///   * Users                 — list / edit / revoke sessions
///   * Quotas                — full CRUD on `/api/admin/quotas`
///   * System credentials    — workspace-shared creds (`/api/admin/credentials`)
///   * MCP pool              — pooled MCP instances connect/disconnect
///   * System packages       — `scope=system` install + uninstall
///   * Activity              — admin audit log
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import 'sections/admin_apps_section.dart';
import 'sections/admin_approvals_section.dart';
import 'sections/admin_audit_section.dart';
import 'sections/admin_mcp_pool_section.dart';
import 'sections/admin_overview_section.dart';
import 'sections/admin_quotas_section.dart';
import 'sections/admin_system_credentials_section.dart';
import 'sections/admin_system_packages_section.dart';
import 'sections/admin_users_section.dart';

class AdminConsolePage extends StatefulWidget {
  /// When true, the page is hosted inside the Settings shell — we
  /// drop the standalone Scaffold and the vertical _AdminSidebar and
  /// instead render a horizontal pill tab bar at the top so we don't
  /// stack two sidebars side by side.
  final bool embedded;
  const AdminConsolePage({super.key, this.embedded = false});

  @override
  State<AdminConsolePage> createState() => _AdminConsolePageState();
}

enum _AdminSection {
  overview,
  users,
  quotas,
  apps,
  approvals,
  systemCredentials,
  mcpPool,
  systemPackages,
  audit,
}

extension on _AdminSection {
  String get label => switch (this) {
        _AdminSection.overview => 'admin.section_overview'.tr(),
        _AdminSection.users => 'admin.section_users'.tr(),
        _AdminSection.quotas => 'admin.section_quotas'.tr(),
        _AdminSection.apps => 'admin.apps'.tr(),
        _AdminSection.approvals => 'admin.approvals'.tr(),
        _AdminSection.systemCredentials =>
          'admin.section_system_credentials'.tr(),
        _AdminSection.mcpPool => 'admin.section_mcp_pool'.tr(),
        _AdminSection.systemPackages => 'admin.section_system_packages'.tr(),
        _AdminSection.audit => 'admin.section_audit'.tr(),
      };

  IconData get icon => switch (this) {
        _AdminSection.overview => Icons.dashboard_outlined,
        _AdminSection.users => Icons.group_outlined,
        _AdminSection.quotas => Icons.speed_rounded,
        _AdminSection.apps => Icons.apps_rounded,
        _AdminSection.approvals => Icons.verified_user_outlined,
        _AdminSection.systemCredentials => Icons.vpn_key_outlined,
        _AdminSection.mcpPool => Icons.electrical_services_rounded,
        _AdminSection.systemPackages => Icons.inventory_2_outlined,
        _AdminSection.audit => Icons.history_rounded,
      };

  String get group => switch (this) {
        _AdminSection.overview => 'admin.group_overview'.tr(),
        _AdminSection.users || _AdminSection.quotas =>
          'admin.group_identity'.tr(),
        _AdminSection.apps || _AdminSection.approvals =>
          'admin.group_apps'.tr(),
        _AdminSection.systemCredentials ||
        _AdminSection.mcpPool ||
        _AdminSection.systemPackages =>
          'admin.group_workspace'.tr(),
        _AdminSection.audit => 'admin.group_audit'.tr(),
      };
}

class _AdminConsolePageState extends State<AdminConsolePage> {
  _AdminSection _active = _AdminSection.overview;

  Widget _activeSection() {
    return KeyedSubtree(
      key: ValueKey(_active),
      child: switch (_active) {
        _AdminSection.overview => const AdminOverviewSection(),
        _AdminSection.users => const AdminUsersSection(),
        _AdminSection.quotas => const AdminQuotasSection(),
        _AdminSection.apps => const AdminAppsSection(),
        _AdminSection.approvals => const AdminApprovalsSection(),
        _AdminSection.systemCredentials =>
          const AdminSystemCredentialsSection(),
        _AdminSection.mcpPool => const AdminMcpPoolSection(),
        _AdminSection.systemPackages =>
          const AdminSystemPackagesSection(),
        _AdminSection.audit => const AdminAuditSection(),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;

    if (widget.embedded) {
      // Embedded mode (inside Settings) — no Scaffold, no vertical
      // sidebar. Top horizontal pill nav + active section. The
      // Settings shell already provides Material chrome around us.
      if (!isAdmin) return _buildForbidden(c);
      return Container(
        color: c.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildEmbeddedHeader(c),
            Expanded(child: _activeSection()),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: c.bg,
      body: !isAdmin
          ? _buildForbidden(c)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AdminSidebar(
                  active: _active,
                  onChange: (s) => setState(() => _active = s),
                ),
                Container(width: 1, color: c.border),
                Expanded(child: _activeSection()),
              ],
            ),
    );
  }

  /// Compact horizontal header used in embedded mode — title +
  /// pill row of section buttons. Replaces the vertical sidebar
  /// so we don't double-stack navigation chrome inside Settings.
  Widget _buildEmbeddedHeader(AppColors c) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final narrow = constraints.maxWidth < 600;
      final hPad = narrow ? 14.0 : 28.0;
      final vPad = narrow ? 14.0 : 22.0;
      final titleSize = narrow ? 17.0 : 22.0;
      final subtitleSize = narrow ? 11.5 : 13.0;
      return Container(
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        padding: EdgeInsets.fromLTRB(hPad, vPad, hPad, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: narrow ? 30 : 36,
                  height: narrow ? 30 : 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [c.purple, c.blue],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: c.purple.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(Icons.shield_rounded,
                      size: narrow ? 15 : 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'admin.title'.tr(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: titleSize,
                          fontWeight: FontWeight.w800,
                          color: c.textBright,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        narrow
                            ? 'admin.subtitle_short'.tr()
                            : 'admin.subtitle_long'.tr(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: subtitleSize,
                          color: c.textMuted,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: narrow ? 12 : 18),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final s in _AdminSection.values)
                  _SectionPill(
                    section: s,
                    selected: _active == s,
                    onTap: () => setState(() => _active = s),
                  ),
              ],
            ),
          ],
        ),
      );
    });
  }

  Widget _buildForbidden(AppColors c) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.orange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: c.orange.withValues(alpha: 0.4)),
                ),
                child: Icon(Icons.shield_outlined,
                    size: 32, color: c.orange),
              ),
              const SizedBox(height: 18),
              Text('admin.forbidden_title'.tr(),
                  style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: c.textBright)),
              const SizedBox(height: 8),
              SizedBox(
                width: 360,
                child: Text(
                  'admin.forbidden_body'.tr(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                      fontSize: 12.5,
                      color: c.textMuted,
                      height: 1.5),
                ),
              ),
              const SizedBox(height: 22),
              ElevatedButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_rounded, size: 14),
                label: Text('admin.back'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: c.blue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      );
}

class _AdminSidebar extends StatelessWidget {
  final _AdminSection active;
  final ValueChanged<_AdminSection> onChange;
  const _AdminSidebar({required this.active, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final all = _AdminSection.values;
    final groups = <String, List<_AdminSection>>{};
    for (final s in all) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    final user = AuthService().currentUser;
    return SizedBox(
      width: 248,
      child: Container(
        color: c.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [c.purple, c.blue],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.shield_rounded,
                        size: 18, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('admin.title'.tr(),
                            style: GoogleFonts.inter(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: c.textBright,
                                letterSpacing: -0.2)),
                        Text(user?.displayName ?? user?.userId ?? 'admin',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.firaCode(
                                fontSize: 9.5,
                                color: c.textMuted)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Groups
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  for (final entry in groups.entries) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                      child: Text(
                        entry.key,
                        style: GoogleFonts.firaCode(
                          fontSize: 9.5,
                          color: c.textMuted,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    for (final s in entry.value)
                      _AdminNavItem(
                        section: s,
                        active: active == s,
                        onTap: () => onChange(s),
                      ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
            // Footer — back button
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.arrow_back_rounded,
                    size: 13, color: c.textMuted),
                label: Text('admin.exit'.tr(),
                    style: GoogleFonts.inter(
                        fontSize: 11,
                        color: c.textMuted,
                        fontWeight: FontWeight.w600)),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminNavItem extends StatefulWidget {
  final _AdminSection section;
  final bool active;
  final VoidCallback onTap;
  const _AdminNavItem({
    required this.section,
    required this.active,
    required this.onTap,
  });

  @override
  State<_AdminNavItem> createState() => _AdminNavItemState();
}

class _AdminNavItemState extends State<_AdminNavItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = widget.active ? c.purple : c.text;
    final bg = widget.active
        ? c.purple.withValues(alpha: 0.12)
        : _h
            ? c.surfaceAlt
            : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(
                color: widget.active
                    ? c.purple.withValues(alpha: 0.4)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(widget.section.icon, size: 14, color: tint),
                const SizedBox(width: 11),
                Text(
                  widget.section.label,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    color: tint,
                    fontWeight: widget.active
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal pill button used by the embedded admin header in
/// place of the vertical sidebar nav. Same styling cue (purple
/// accent for active) as the standalone _AdminNavItem so the user
/// recognises it across both layouts.
class _SectionPill extends StatefulWidget {
  final _AdminSection section;
  final bool selected;
  final VoidCallback onTap;
  const _SectionPill({
    required this.section,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_SectionPill> createState() => _SectionPillState();
}

class _SectionPillState extends State<_SectionPill> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = widget.selected ? c.purple : c.textMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding:
              const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? c.purple.withValues(alpha: 0.12)
                : (_h ? c.surfaceAlt : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? c.purple.withValues(alpha: 0.4)
                  : c.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.section.icon, size: 14, color: tint),
              const SizedBox(width: 8),
              Text(
                widget.section.label,
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  color: widget.selected ? c.textBright : c.text,
                  fontWeight: widget.selected
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
