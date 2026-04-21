/// Multi-section settings shell. Two layouts:
///
///   * Desktop (≥ 600px wide): left sidebar with profile card, search
///     bar, grouped navigation; right pane holds the active section.
///   * Mobile (< 600px wide): two-screen drill with grouped list on
///     the entry screen, detail pane after selection.
///
/// Sections are independent widgets that fetch their own data on init
/// so the shell stays cheap to mount.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../main.dart';
import '../../services/auth_service.dart';
import '../../theme/app_theme.dart';
import '../admin/admin_console_page.dart';
import '../credentials_v2/credentials_manager_page.dart';
import '../hub/hub_page.dart';
import 'sections/about_section.dart';
import 'sections/app_permissions_section.dart';
import 'sections/appearance_section.dart';
import 'sections/general_section.dart';
import 'sections/language_section.dart';
import 'sections/notifications_section.dart';
import 'sections/security_sessions_section.dart';
import 'sections/usage_section.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _SettingsSection _active = _SettingsSection.general;
  bool _mobileDetail = false;
  String _query = '';

  void _closeSettings(BuildContext context) {
    final state = context.read<AppState>();
    state.setPanel(
      state.activeApp != null ? ActivePanel.chat : ActivePanel.dashboard,
    );
  }

  Widget _buildSection(_SettingsSection s) => switch (s) {
        _SettingsSection.general => const GeneralSection(),
        _SettingsSection.appearance => const AppearanceSection(),
        _SettingsSection.language => const LanguageSection(),
        _SettingsSection.notifications => const NotificationsSection(),
        _SettingsSection.usage => const UsageSection(),
        _SettingsSection.credentials =>
          const CredentialsManagerPage(embedded: true),
        _SettingsSection.permissions => const AppPermissionsSection(),
        _SettingsSection.security => const Padding(
            padding: EdgeInsets.fromLTRB(36, 28, 36, 36),
            child: SecuritySessionsSection(),
          ),
        _SettingsSection.hub => const HubPage(embedded: true),
        _SettingsSection.admin => const AdminConsolePage(embedded: true),
        _SettingsSection.about => const AboutSection(),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(builder: (ctx, constraints) {
      final isMobile = constraints.maxWidth < 720;
      if (isMobile) return _buildMobile(c);
      return _buildDesktop(c);
    });
  }

  Widget _buildDesktop(AppColors c) {
    return Container(
      color: c.bg,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SettingsSidebar(
            active: _active,
            query: _query,
            onQueryChanged: (q) => setState(() => _query = q),
            onChange: (s) => setState(() => _active = s),
            onClose: () => _closeSettings(context),
          ),
          Container(width: 1, color: c.border),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(_active),
              child: _buildSection(_active),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobile(AppColors c) {
    if (!_mobileDetail) {
      return Container(
        color: c.bg,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _MobileHeader(
              title: 'settings.title'.tr(),
              onBack: () => _closeSettings(context),
              backIcon: Icons.close_rounded,
            ),
            Container(height: 1, color: c.border),
            Expanded(
              child: _SettingsMobileList(
                onSelect: (s) => setState(() {
                  _active = s;
                  _mobileDetail = true;
                }),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      color: c.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MobileHeader(
            title: _active.label,
            onBack: () => setState(() => _mobileDetail = false),
            backIcon: Icons.arrow_back_rounded,
          ),
          Container(height: 1, color: c.border),
          Expanded(
            child: KeyedSubtree(
              key: ValueKey(_active),
              child: _buildSection(_active),
            ),
          ),
        ],
      ),
    );
  }
}

enum _SettingsSection {
  general,
  appearance,
  language,
  notifications,
  usage,
  credentials,
  permissions,
  security,
  hub,
  admin,
  about,
}

extension on _SettingsSection {
  String get label => switch (this) {
        _SettingsSection.general => 'settings.section_general'.tr(),
        _SettingsSection.appearance => 'settings.section_appearance'.tr(),
        _SettingsSection.language => 'settings.section_language'.tr(),
        _SettingsSection.notifications =>
          'settings.section_notifications'.tr(),
        _SettingsSection.usage => 'settings.section_usage'.tr(),
        _SettingsSection.credentials => 'settings.section_credentials'.tr(),
        _SettingsSection.permissions => 'settings.section_permissions'.tr(),
        _SettingsSection.security => 'Security',
        _SettingsSection.hub => 'settings.section_hub'.tr(),
        _SettingsSection.admin => 'settings.section_admin'.tr(),
        _SettingsSection.about => 'settings.section_about'.tr(),
      };

  String get hint => switch (this) {
        _SettingsSection.general => 'settings.section_general_hint'.tr(),
        _SettingsSection.appearance =>
          'settings.section_appearance_hint'.tr(),
        _SettingsSection.language => 'settings.section_language_hint'.tr(),
        _SettingsSection.notifications =>
          'settings.section_notifications_hint'.tr(),
        _SettingsSection.usage => 'settings.section_usage_hint'.tr(),
        _SettingsSection.credentials =>
          'settings.section_credentials_hint'.tr(),
        _SettingsSection.permissions =>
          'settings.section_permissions_hint'.tr(),
        _SettingsSection.security =>
          'Active devices + revoke, fork token, audit history',
        _SettingsSection.hub => 'settings.section_hub_hint'.tr(),
        _SettingsSection.admin => 'settings.section_admin_hint'.tr(),
        _SettingsSection.about => 'settings.section_about_hint'.tr(),
      };

  IconData get icon => switch (this) {
        _SettingsSection.general => Icons.person_outline_rounded,
        _SettingsSection.appearance => Icons.palette_outlined,
        _SettingsSection.language => Icons.language_rounded,
        _SettingsSection.notifications => Icons.notifications_none_rounded,
        _SettingsSection.usage => Icons.bar_chart_rounded,
        _SettingsSection.credentials => Icons.key_outlined,
        _SettingsSection.permissions => Icons.shield_outlined,
        _SettingsSection.security => Icons.lock_outline_rounded,
        _SettingsSection.hub => Icons.extension_rounded,
        _SettingsSection.admin => Icons.admin_panel_settings_outlined,
        _SettingsSection.about => Icons.info_outline_rounded,
      };

  String get group => switch (this) {
        _SettingsSection.general ||
        _SettingsSection.appearance ||
        _SettingsSection.language ||
        _SettingsSection.notifications =>
          'settings.group_preferences'.tr(),
        _SettingsSection.usage ||
        _SettingsSection.credentials ||
        _SettingsSection.permissions ||
        _SettingsSection.security ||
        _SettingsSection.hub =>
          'settings.group_workspace'.tr(),
        _SettingsSection.admin => 'settings.group_admin'.tr(),
        _SettingsSection.about => 'settings.group_info'.tr(),
      };
}

// ─── Mobile header ───────────────────────────────────────────────────────────

class _MobileHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  final IconData backIcon;
  const _MobileHeader({
    required this.title,
    required this.onBack,
    this.backIcon = Icons.arrow_back_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          IconButton(
            onPressed: onBack,
            icon: Icon(backIcon, color: c.textBright),
            tooltip: backIcon == Icons.close_rounded
                ? 'common.close'.tr()
                : 'common.back'.tr(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: c.textBright,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mobile list ─────────────────────────────────────────────────────────────

class _SettingsMobileList extends StatelessWidget {
  final ValueChanged<_SettingsSection> onSelect;
  const _SettingsMobileList({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    final all = _SettingsSection.values
        .where((s) => s != _SettingsSection.admin || isAdmin)
        .toList();
    final groups = <String, List<_SettingsSection>>{};
    for (final s in all) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const _UserCard(compact: true),
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
            child: Text(
              entry.key,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: c.textMuted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final s in entry.value)
            InkWell(
              onTap: () => onSelect(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: c.accentPrimary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: c.accentPrimary.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Icon(s.icon,
                          size: 17, color: c.accentPrimary),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.label,
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              color: c.textBright,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            s.hint,
                            style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: c.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 20, color: c.textMuted),
                  ],
                ),
              ),
            ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}

// ─── Desktop sidebar ─────────────────────────────────────────────────────────

class _SettingsSidebar extends StatelessWidget {
  final _SettingsSection active;
  final String query;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<_SettingsSection> onChange;
  final VoidCallback onClose;
  const _SettingsSidebar({
    required this.active,
    required this.query,
    required this.onQueryChanged,
    required this.onChange,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isAdmin = AuthService().currentUser?.isAdmin ?? false;
    final all = _SettingsSection.values
        .where((s) => s != _SettingsSection.admin || isAdmin)
        .toList();
    final q = query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all
            .where((s) =>
                s.label.toLowerCase().contains(q) ||
                s.hint.toLowerCase().contains(q) ||
                s.group.toLowerCase().contains(q))
            .toList();
    final groups = <String, List<_SettingsSection>>{};
    for (final s in filtered) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    return SizedBox(
      width: 288,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              c.surface,
              Color.lerp(c.surface, c.accentPrimary, 0.02) ?? c.surface,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Back row
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
              child: _BackRow(onTap: onClose),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 4, 22, 14),
              child: Text(
                'settings.title'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: c.textBright,
                  letterSpacing: -0.4,
                ),
              ),
            ),
            // User card
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: _UserCard(),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
              child: _SearchField(
                value: query,
                onChanged: onQueryChanged,
              ),
            ),
            Expanded(
              child: filtered.isEmpty
                  ? _EmptyResult(query: q)
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 24),
                      children: [
                        for (final entry in groups.entries) ...[
                          Padding(
                            padding:
                                const EdgeInsets.fromLTRB(12, 14, 12, 6),
                            child: Text(
                              entry.key,
                              style: GoogleFonts.firaCode(
                                fontSize: 10.5,
                                color: c.textMuted,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.9,
                              ),
                            ),
                          ),
                          for (final s in entry.value)
                            _NavItem(
                              section: s,
                              active: active == s,
                              onTap: () => onChange(s),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BackRow extends StatefulWidget {
  final VoidCallback onTap;
  const _BackRow({required this.onTap});
  @override
  State<_BackRow> createState() => _BackRowState();
}

class _BackRowState extends State<_BackRow> {
  bool _h = false;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _h = true),
      onExit: (_) => setState(() => _h = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.arrow_back_rounded,
                  size: 14,
                  color: _h ? c.textBright : c.textMuted),
              const SizedBox(width: 6),
              Text(
                'settings.back_to_workspace'.tr(),
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: _h ? c.textBright : c.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  final bool compact;
  const _UserCard({this.compact = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final user = AuthService().currentUser;
    final name = user?.displayName?.trim().isNotEmpty == true
        ? user!.displayName!
        : (user?.email?.split('@').first ?? 'Guest');
    final email = user?.email ?? 'Not signed in';
    final initials = _initials(name);
    return Container(
      margin: compact
          ? const EdgeInsets.fromLTRB(16, 12, 16, 6)
          : EdgeInsets.zero,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.accentPrimary, c.accentSecondary],
              ),
              boxShadow: [
                BoxShadow(
                  color: c.glow.withValues(alpha: 0.28),
                  blurRadius: 10,
                  spreadRadius: -2,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: c.onAccent,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: c.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (user?.isAdmin == true)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: c.accentPrimary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: c.accentPrimary.withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                'settings.admin_badge'.tr(),
                style: GoogleFonts.firaCode(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: c.accentPrimary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }
}

class _SearchField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.value, required this.onChanged});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  final _focus = FocusNode();
  late final TextEditingController _ctrl;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
    _focus.addListener(() {
      if (!mounted) return;
      setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void didUpdateWidget(covariant _SearchField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        color: c.inputBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: _focused ? c.accentPrimary : c.inputBorder,
          width: _focused ? 1.3 : 1,
        ),
        boxShadow: _focused
            ? [
                BoxShadow(
                  color: c.accentPrimary.withValues(alpha: 0.18),
                  blurRadius: 8,
                  spreadRadius: -2,
                ),
              ]
            : const [],
      ),
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        onChanged: widget.onChanged,
        style: GoogleFonts.inter(fontSize: 13, color: c.textBright),
        cursorColor: c.textBright,
        cursorWidth: 1.2,
        decoration: InputDecoration(
          hintText: 'settings.search_settings'.tr(),
          hintStyle:
              GoogleFonts.inter(fontSize: 13, color: c.textMuted),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Icon(Icons.search_rounded,
                size: 16,
                color: _focused ? c.accentPrimary : c.textMuted),
          ),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
          suffixIcon: widget.value.isNotEmpty
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () {
                      _ctrl.clear();
                      widget.onChanged('');
                    },
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.close_rounded,
                          size: 14, color: c.textMuted),
                    ),
                  ),
                )
              : null,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  final String query;
  const _EmptyResult({required this.query});
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          const SizedBox(height: 40),
          Icon(Icons.search_off_rounded,
              size: 24, color: c.textMuted),
          const SizedBox(height: 10),
          Text(
            'settings.no_settings_match'.tr(),
            style: GoogleFonts.inter(
                fontSize: 13,
                color: c.textBright,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '"$query"',
            textAlign: TextAlign.center,
            style: GoogleFonts.firaCode(fontSize: 11, color: c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final _SettingsSection section;
  final bool active;
  final VoidCallback onTap;
  const _NavItem({
    required this.section,
    required this.active,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _h = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = widget.active;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _h = true),
        onExit: (_) => setState(() => _h = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 9),
                decoration: BoxDecoration(
                  color: active
                      ? Color.lerp(
                              c.surfaceAlt, c.accentPrimary, 0.10) ??
                          c.surfaceAlt
                      : (_h ? c.surfaceAlt : null),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: active
                        ? c.accentPrimary.withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: c.glow.withValues(alpha: 0.18),
                            blurRadius: 14,
                            spreadRadius: -6,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: active
                            ? c.accentPrimary.withValues(alpha: 0.18)
                            : c.surfaceAlt,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(
                        widget.section.icon,
                        size: 15,
                        color: active ? c.accentPrimary : c.text,
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.section.label,
                            style: GoogleFonts.inter(
                              fontSize: 13.5,
                              color: active ? c.textBright : c.text,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Active rail indicator — thin accent bar on the left.
              if (active)
                Positioned(
                  left: -10,
                  top: 10,
                  bottom: 10,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [c.accentPrimary, c.accentSecondary],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
